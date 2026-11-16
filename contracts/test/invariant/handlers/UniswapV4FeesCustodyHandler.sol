// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../../src/amm/IAmmIntegration.sol";
import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {IUniswapV4Integration} from "../../../src/amm/uniswap-v4/IUniswapV4Integration.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {IV4TestPositionManager, V4PoolActor} from "../../utils/fixtures/UniswapV4WorldFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice The StateView reads the handler takes its fee figures from, independently of the LPVault's own
/// `UniswapV4State` (v4-periphery `StateView`, deployed from `out-univ4/`).
interface IV4StateViewFees {
    function getPositionInfo(
        bytes32 poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128);

    function getFeeGrowthInside(
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128);
}

/// @notice What the handler needs from the suite that runs it: minting through the fixture's PositionManager, which
/// the suite pays for.
interface IV4InvariantSource {
    function v4MintFor(
        uint256 marketId,
        address owner,
        uint128 liquidity
    ) external returns (bytes32 key);
}

/// @title UniswapV4FeesCustodyHandler
/// @notice Actor handler of the Uniswap v4 LPVault's fee and custody suite, on the real PoolManager and
/// PositionManager: two depositors pledge positions of a USDC/USDT and a native ETH/USDC market through
/// Collateralization (under the AaveAdapter's Lock), partly remove, collect fees naming the depositor, the other depositor
/// or an attacker, and withdraw; LPVaultSwap seizes and Collateralization reconciles any part of a position's units;
/// swaps, spot moves and donations on the PoolManager accrue fees; the second depositor's address can be blocklisted
/// by USDC (every USDC transfer to it reverts), which is the case the LPVault's fallback removal exists for
/// (`REQ-AMM-V4-013`); an attacker pushes NFTs to the LPVault, calls custody functions directly and tries to move or
/// decrease custodied positions on the PositionManager; the timelock returns strays. Ghosts record per position the
/// fees accrued (from StateView, around each pool action), the fees paid to the depositor, the fees a fallback removal
/// sent to the recipient and the fees left in a position at withdrawal, and count every payout outside the rules.
contract UniswapV4FeesCustodyHandler is CommonBase, StdUtils {
    /// @notice A call that found nothing to act on, or that the contract refused as it must: reverting keeps it out of
    /// the campaign's success count, so the metrics show the calls that did real work.
    error Skipped();

    uint256 internal constant MAX_POSITIONS = 8;
    uint256 internal constant MAX_STRAYS = 4;
    uint256 internal constant Q128 = 1 << 128;
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant TAKE_PAIR = 0x11;
    /// @dev Actors whose balances are watched, and the three tokens of the two markets (USDC, USDT, WETH).
    uint256 internal constant ACTORS = 9;
    uint256 internal constant TOKENS = 3;

    IUniswapV4Integration public immutable VAULT;
    IV4TestPositionManager public immutable POSM;
    V4PoolActor public immutable POOL_ACTOR;
    IV4StateViewFees public immutable STATE_VIEW;
    IV4InvariantSource public immutable SOURCE;
    Lock public immutable LOCK;
    address public immutable ADAPTER;
    address public immutable COLL;
    address public immutable SWAP;
    address public immutable TIMELOCK;
    address public immutable ATTACKER;
    /// @notice The token a depositor can be blocklisted by, and that depositor.
    address public immutable BLOCKING_TOKEN;
    address public immutable BLOCKABLE;
    address[2] internal depositors;

    /// @dev Per market (index `marketId - 1`): pool key, pool id, range, the market's tokens as indexes into `tokens`,
    /// the band the pool's price is kept in and the bounds of a swap's exact input per direction.
    PoolKey[2] internal poolKeys;
    bytes32[2] internal poolIds;
    int24[2] internal lowers;
    int24[2] internal uppers;
    uint256[2][2] internal tokenIdx;
    int24[2] internal bandLow;
    int24[2] internal bandHigh;
    uint256[2][2] internal swapMax;
    uint128[2][2] internal pledgeBounds;
    address[TOKENS] public tokens;
    address[ACTORS] public actors;

    bytes32[] public keys;
    mapping(bytes32 key => address depositor) public depositorOfKey;
    mapping(bytes32 key => uint256 marketId) public marketOfKey;
    mapping(bytes32 key => bool open) public isOpen;
    mapping(bytes32 key => uint256[2] amounts) internal _accrued;
    mapping(bytes32 key => uint256[2] amounts) internal _paid;
    mapping(bytes32 key => uint256[2] amounts) internal _forfeited;
    mapping(bytes32 key => uint256[2] amounts) internal _leftWithNft;

    bytes32[] public strays;
    mapping(bytes32 key => address sender) public senderOf;
    mapping(bytes32 key => bool returned) public strayReturned;

    /// @notice Whether `BLOCKABLE` is blocklisted by `BLOCKING_TOKEN` now.
    bool public blocked;
    uint256 public openCount;

    /// @notice Pool tokens that reached anyone but the position's depositor, or the removal's recipient for its
    /// reported amounts, during an LPVault call.
    uint256 public paidToOthers;
    /// @notice A collection naming someone other than the depositor that succeeded.
    uint256 public foreignCollections;
    /// @notice A collection that paid other than exactly the owed fees, or left fees owed.
    uint256 public wrongCollections;
    /// @notice A release to the depositor whose fee part was other than exactly the owed fees.
    uint256 public wrongReleases;
    /// @notice A seizure (removal to LPVaultSwap or Collateralization) that paid an accepting depositor other than
    /// exactly the owed fees, or that paid a blocklisted depositor anything or returned less than the owed fees.
    uint256 public feesCut;
    /// @notice A removal whose recipient received other than the amounts the LPVault returned.
    uint256 public recipientMismatch;
    /// @notice A pool action that lowered a custodied position's owed fees (only LPVault calls may).
    uint256 public owedFell;
    /// @notice A call that must fail and succeeded: a direct custody call, a stray return of a custodied position, an
    /// attacker moving or decreasing a custodied position on the PositionManager.
    uint256 public forbiddenSuccesses;
    /// @notice A call the rules say must succeed and that failed: a pledge, a seizure (also of a blocklisted
    /// depositor's position), a reconciliation, a collection, a release or withdrawal of an accepting depositor, a
    /// stray return.
    uint256 public liveFailures;
    uint256 public fallbackSeizures;
    uint256 public acceptedSeizures;
    uint256 public collections;

    struct Wiring {
        IUniswapV4Integration vault;
        IV4TestPositionManager posm;
        V4PoolActor poolActor;
        IV4StateViewFees stateView;
        IV4InvariantSource source;
        Lock lock;
    }

    constructor(
        Wiring memory w,
        address[5] memory roles,
        address[2] memory depositors_,
        PoolKey[2] memory keys_,
        address weth
    ) {
        (VAULT, POSM, POOL_ACTOR, STATE_VIEW, SOURCE, LOCK) =
            (w.vault, w.posm, w.poolActor, w.stateView, w.source, w.lock);
        (ADAPTER, COLL, SWAP, TIMELOCK, ATTACKER) = (roles[0], roles[1], roles[2], roles[3], roles[4]);
        depositors = depositors_;
        BLOCKABLE = depositors_[1];
        for (uint256 i = 0; i < 2; ++i) {
            poolKeys[i] = keys_[i];
            poolIds[i] = keccak256(abi.encode(keys_[i]));
            (,, PositionShape memory s,) = w.vault.marketOf(i + 1);
            (lowers[i], uppers[i]) = (s.tickLower, s.tickUpper);
        }
        // Market 1 (USDC/USDT) and market 2 (WETH/USDC) share USDC, the token that can blocklist.
        (,,, address[] memory t1) = VAULT.marketOf(1);
        (,,, address[] memory t2) = VAULT.marketOf(2);
        address usdc = t2[1];
        BLOCKING_TOKEN = usdc;
        tokens = [usdc, t1[0] == usdc ? t1[1] : t1[0], weth];
        tokenIdx[0] = t1[0] == usdc ? [uint256(0), 1] : [uint256(1), 0];
        tokenIdx[1] = [uint256(2), 0];
        // The price bands: both sides of each market's range are reachable.
        (bandLow[0], bandHigh[0]) = (-150, 150);
        (bandLow[1], bandHigh[1]) = (lowers[1] - 1000, uppers[1] + 1000);
        swapMax[0] = [uint256(1e12), 1e12];
        swapMax[1] = [uint256(1e21), 1e12];
        pledgeBounds[0] = [uint128(1e12), 1e15];
        pledgeBounds[1] = [uint128(1e14), 1e17];
        actors = [depositors_[0], depositors_[1], ATTACKER, SWAP, COLL, address(VAULT), ADAPTER, TIMELOCK, address(POSM)];
    }

    // ─── Views for the suite ───

    function keyCount() external view returns (uint256) {
        return keys.length;
    }

    function strayCount() external view returns (uint256) {
        return strays.length;
    }

    function accrued(
        bytes32 key
    ) external view returns (uint256, uint256) {
        return (_accrued[key][0], _accrued[key][1]);
    }

    function paid(
        bytes32 key
    ) external view returns (uint256, uint256) {
        return (_paid[key][0], _paid[key][1]);
    }

    function forfeited(
        bytes32 key
    ) external view returns (uint256, uint256) {
        return (_forfeited[key][0], _forfeited[key][1]);
    }

    function leftWithNft(
        bytes32 key
    ) external view returns (uint256, uint256) {
        return (_leftWithNft[key][0], _leftWithNft[key][1]);
    }

    /// @notice The fees the PoolManager credits the position on its next liquidity change, from StateView:
    /// `mulDiv(inside - last, liquidity, 2^128)` per token, the difference modulo 2^256.
    function owed(
        bytes32 key
    ) public view returns (uint256 o0, uint256 o1) {
        uint256 i = marketOfKey[key] - 1;
        (uint128 liq, uint256 last0, uint256 last1) =
            STATE_VIEW.getPositionInfo(poolIds[i], address(POSM), lowers[i], uppers[i], key);
        if (liq == 0) return (0, 0);
        (uint256 in0, uint256 in1) = STATE_VIEW.getFeeGrowthInside(poolIds[i], lowers[i], uppers[i]);
        uint256 d0;
        uint256 d1;
        unchecked {
            d0 = in0 - last0;
            d1 = in1 - last1;
        }
        return (Math.mulDiv(d0, liq, Q128), Math.mulDiv(d1, liq, Q128));
    }

    // ─── Depositors ───

    function pledge(
        uint256 who,
        uint256 marketSeed,
        uint128 liquidity
    ) external {
        _applyBlock();
        if (openCount >= MAX_POSITIONS || keys.length >= 2 * MAX_POSITIONS) revert Skipped();
        address owner = depositors[who % 2];
        uint256 marketId = 1 + marketSeed % 2;
        uint128[2] memory b = pledgeBounds[marketId - 1];
        bytes32 key = SOURCE.v4MintFor(marketId, owner, uint128(bound(liquidity, b[0], b[1])));
        (bool ok,) = _asColl(ADAPTER, abi.encodeCall(IAmmIntegration.receivePosition, (marketId, owner, key)));
        if (!ok) {
            ++liveFailures;
            return;
        }
        keys.push(key);
        (depositorOfKey[key], marketOfKey[key], isOpen[key]) = (owner, marketId, true);
        ++openCount;
    }

    function partialRemoval(
        uint256 keySeed,
        uint256 unitsSeed
    ) external {
        _applyBlock();
        (bytes32 key, uint128 units) = _pickUnits(keySeed, unitsSeed, false);
        address depositor = depositorOfKey[key];
        (uint256 o0, uint256 o1) = owed(key);
        uint256[] memory s = _snap();
        (bool ok, bytes memory ret) =
            _asColl(ADAPTER, abi.encodeCall(IAmmIntegration.releaseToDepositor, (key, units, new uint256[](2))));
        if (!ok) {
            // A depositor that cannot receive blocks only their own release (`REQ-AMM-V4-013`).
            if (!_isBlocked(depositor)) {
                ++liveFailures;
                return;
            }
            revert Skipped();
        }
        uint256[] memory amounts = abi.decode(ret, (uint256[]));
        paidToOthers += _othersReceived(s, _actorIndex(depositor), type(uint256).max);
        (uint256 f0, uint256 f1) = _feePart(s, key, depositor, amounts);
        if (f0 != o0 || f1 != o1) ++wrongReleases;
        _credit(_paid, key, f0, f1);
    }

    function collect(
        uint256 keySeed,
        uint256 callerSeed
    ) external {
        _applyBlock();
        bytes32 key = _openKey(keySeed);
        if (key == bytes32(0)) revert Skipped();
        address depositor = depositorOfKey[key];
        // The depositor in half the calls, the other depositor or the attacker in the rest.
        uint256 pick = callerSeed % 4;
        address named = pick < 2 ? depositor : pick == 2 ? depositors[depositor == depositors[0] ? 1 : 0] : ATTACKER;
        (uint256 o0, uint256 o1) = owed(key);
        uint256[] memory s = _snap();
        (bool ok, bytes memory ret) = _asColl(ADAPTER, abi.encodeCall(IAmmIntegration.collectFees, (key, named)));
        paidToOthers += _othersReceived(s, _actorIndex(depositor), type(uint256).max);
        if (!ok) {
            if (named == depositor && !_isBlocked(depositor)) {
                ++liveFailures;
                return;
            }
            revert Skipped();
        }
        if (named != depositor) {
            ++foreignCollections;
            return;
        }
        _checkCollection(key, depositor, o0, o1, s, abi.decode(ret, (uint256[])));
    }

    /// @dev A collection must pay the depositor exactly the owed fees and leave none owed.
    function _checkCollection(
        bytes32 key,
        address depositor,
        uint256 o0,
        uint256 o1,
        uint256[] memory s,
        uint256[] memory amounts
    ) internal {
        uint256 d = _actorIndex(depositor);
        uint256[2] memory t = tokenIdx[marketOfKey[key] - 1];
        (uint256 n0, uint256 n1) = owed(key);
        if (
            amounts[0] != o0 || amounts[1] != o1 || n0 != 0 || n1 != 0 || _received(s, d, t[0]) != o0
                || _received(s, d, t[1]) != o1
        ) ++wrongCollections;
        _credit(_paid, key, amounts[0], amounts[1]);
        ++collections;
    }

    function withdraw(
        uint256 keySeed
    ) external {
        _applyBlock();
        bytes32 key = _openKey(keySeed);
        if (key == bytes32(0)) revert Skipped();
        (uint256 o0, uint256 o1) = owed(key);
        uint256[] memory s = _snap();
        (bool ok,) = _asColl(ADAPTER, abi.encodeCall(IAmmIntegration.returnPosition, (key)));
        if (!ok) {
            ++liveFailures;
            return;
        }
        // The NFT carries its owed fees; no token moves.
        paidToOthers += _othersReceived(s, type(uint256).max, type(uint256).max);
        isOpen[key] = false;
        --openCount;
        _credit(_leftWithNft, key, o0, o1);
    }

    // ─── LPVaultSwap and Collateralization ───

    /// @notice A removal of `units` to LPVaultSwap (a seizure, under LPVaultSwap's Lock session) or to
    /// Collateralization (a reconciliation, under the AaveAdapter's): the depositor receives exactly the owed fees,
    /// unless USDC refuses the depositor, when the recipient receives them with the principal (`REQ-AMM-V4-013`).
    function seize(
        uint256 keySeed,
        uint256 unitsSeed,
        bool reconcile
    ) external {
        _applyBlock();
        (bytes32 key, uint128 units) = _pickUnits(keySeed, unitsSeed, true);
        address recipient = reconcile ? COLL : SWAP;
        uint256[2] memory o;
        (o[0], o[1]) = owed(key);
        uint256[] memory s = _snap();
        (bool ok, bytes memory ret) = _asColl(
            reconcile ? ADAPTER : SWAP,
            abi.encodeCall(IAmmIntegration.unwind, (key, units, new uint256[](2), recipient))
        );
        if (!ok) {
            ++liveFailures;
            return;
        }
        _checkSeizure(key, recipient, o, s, abi.decode(ret, (uint256[])));
    }

    /// @dev The payouts of a seizure or reconciliation of `key` to `recipient` that owed `o` before.
    function _checkSeizure(
        bytes32 key,
        address recipient,
        uint256[2] memory o,
        uint256[] memory s,
        uint256[] memory amounts
    ) internal {
        address depositor = depositorOfKey[key];
        uint256 d = _actorIndex(depositor);
        uint256 r = _actorIndex(recipient);
        paidToOthers += _othersReceived(s, d, r);
        uint256[2] memory t = tokenIdx[marketOfKey[key] - 1];
        if (_received(s, r, t[0]) != amounts[0] || _received(s, r, t[1]) != amounts[1]) ++recipientMismatch;
        uint256 f0 = _received(s, d, t[0]);
        uint256 f1 = _received(s, d, t[1]);
        // The fee step pays the depositor only the tokens with fees owed (v4-periphery skips a zero take), so USDC
        // refuses it exactly when the depositor is blocklisted and owed USDC fees.
        if (_isBlocked(depositor) && (t[0] == 0 ? o[0] : o[1]) > 0) {
            if (f0 + f1 != 0 || amounts[0] < o[0] || amounts[1] < o[1]) ++feesCut;
            _credit(_forfeited, key, o[0], o[1]);
            ++fallbackSeizures;
        } else {
            if (f0 != o[0] || f1 != o[1]) ++feesCut;
            _credit(_paid, key, f0, f1);
            ++acceptedSeizures;
        }
    }

    // ─── Pool, blocklist, attacker and timelock ───

    /// @notice An exact-input swap of the market's pool, kept inside its price band; accrues fees.
    function swap(
        uint256 marketSeed,
        bool zeroForOne,
        uint256 amountSeed
    ) external {
        _applyBlock();
        uint256 i = marketSeed % 2;
        uint256 amount = bound(amountSeed, swapMax[i][zeroForOne ? 0 : 1] / 1e6, swapMax[i][zeroForOne ? 0 : 1]);
        uint160 limit = ClPriceMath.sqrtRatioAtTick(zeroForOne ? bandLow[i] : bandHigh[i]);
        uint256[2][] memory before = _owedAll();
        try POOL_ACTOR.swap(poolKeys[i], zeroForOne, -int256(amount), limit) {}
        catch {
            revert Skipped();
        }
        _accrueFrom(before);
    }

    /// @notice A swap to a price in the market's band, across the range's bounds and back; accrues fees.
    function moveSpot(
        uint256 marketSeed,
        int24 tick
    ) external {
        _applyBlock();
        uint256 i = marketSeed % 2;
        uint160 target = ClPriceMath.sqrtRatioAtTick(int24(bound(int256(tick), bandLow[i], bandHigh[i])));
        bytes32 id = poolIds[i];
        (uint160 now_,) = _slot0(id);
        if (target == now_) revert Skipped();
        uint256[2][] memory before = _owedAll();
        POOL_ACTOR.swap(poolKeys[i], target < now_, -int256(uint256(type(uint128).max)), target);
        _accrueFrom(before);
    }

    /// @notice A donation to the pool's in-range liquidity; accrues fees to in-range positions.
    function donate(
        uint256 marketSeed,
        uint256 a0,
        uint256 a1
    ) external {
        _applyBlock();
        uint256 i = marketSeed % 2;
        a0 = bound(a0, 0, swapMax[i][0] / 1e3);
        a1 = bound(a1, 0, swapMax[i][1] / 1e3);
        if (a0 + a1 == 0) revert Skipped();
        uint256[2][] memory before = _owedAll();
        POOL_ACTOR.donate(poolKeys[i], a0, a1);
        _accrueFrom(before);
    }

    /// @notice USDC blocklists the second depositor's address, or lifts the blocklist.
    function toggleBlocked() external {
        blocked = !blocked;
        _applyBlock();
    }

    function pushStray(
        uint128 liquidity,
        bool safe
    ) external {
        _applyBlock();
        if (strays.length >= MAX_STRAYS) revert Skipped();
        bytes32 key = SOURCE.v4MintFor(1, ATTACKER, uint128(bound(liquidity, 1e9, 1e12)));
        vm.prank(ATTACKER);
        if (safe) IERC721(address(POSM)).safeTransferFrom(ATTACKER, address(VAULT), uint256(key));
        else POSM.transferFrom(ATTACKER, address(VAULT), uint256(key));
        strays.push(key);
        senderOf[key] = ATTACKER;
    }

    function returnStray(
        uint256 seed,
        bool tryCustodied
    ) external {
        _applyBlock();
        if (tryCustodied) {
            bytes32 key = _openKey(seed);
            if (key == bytes32(0)) revert Skipped();
            vm.prank(TIMELOCK);
            (bool ok,) = address(VAULT).call(abi.encodeCall(VAULT.returnStray, (key, ATTACKER)));
            if (ok) ++forbiddenSuccesses;
            return;
        }
        if (strays.length == 0) revert Skipped();
        bytes32 stray = strays[seed % strays.length];
        if (strayReturned[stray]) revert Skipped();
        vm.prank(TIMELOCK);
        (bool ok2,) = address(VAULT).call(abi.encodeCall(VAULT.returnStray, (stray, senderOf[stray])));
        if (!ok2) {
            ++liveFailures;
            return;
        }
        strayReturned[stray] = true;
    }

    /// @notice A custody call made directly by an attacker, the AaveAdapter, LPVaultSwap or the timelock (not through
    /// Collateralization) inside either Lock member's session, or the attacker moving or decreasing a custodied
    /// position on the PositionManager: every one must fail.
    function attack(
        uint256 keySeed,
        uint256 which,
        uint256 callerSeed,
        bool swapSession
    ) external {
        _applyBlock();
        if (keys.length == 0) revert Skipped();
        bytes32 key = keys[keySeed % keys.length];
        which %= 7;
        bool ok;
        if (which == 5) {
            if (!isOpen[key]) revert Skipped();
            vm.prank(ATTACKER);
            (ok,) = address(POSM).call(
                abi.encodeWithSignature(
                    "transferFrom(address,address,uint256)", address(VAULT), ATTACKER, uint256(key)
                )
            );
        } else if (which == 6) {
            if (!isOpen[key]) revert Skipped();
            vm.prank(ATTACKER);
            (ok,) = address(POSM).call(abi.encodeCall(POSM.modifyLiquidities, (_drain(key), block.timestamp)));
        } else {
            address[4] memory callers = [ATTACKER, ADAPTER, SWAP, TIMELOCK];
            bytes[5] memory calls = [
                abi.encodeCall(IAmmIntegration.returnPosition, (key)),
                abi.encodeCall(IAmmIntegration.unwind, (key, 1, new uint256[](2), ATTACKER)),
                abi.encodeCall(IAmmIntegration.releaseToDepositor, (key, 1, new uint256[](2))),
                abi.encodeCall(IAmmIntegration.collectFees, (key, ATTACKER)),
                abi.encodeCall(IAmmIntegration.receivePosition, (1, ATTACKER, key))
            ];
            address holder = swapSession ? SWAP : ADAPTER;
            vm.prank(holder);
            LOCK.acquire();
            vm.prank(callers[callerSeed % 4]);
            (ok,) = address(VAULT).call(calls[which]);
            vm.prank(holder);
            LOCK.release();
        }
        if (ok) ++forbiddenSuccesses;
    }

    // ─── Internal ───

    /// @dev Mock state is not part of the EVM state a run restores, so every action sets it from `blocked` first.
    function _applyBlock() internal {
        vm.clearMockedCalls();
        if (blocked) {
            vm.mockCallRevert(
                BLOCKING_TOKEN, abi.encodeWithSelector(IERC20.transfer.selector, BLOCKABLE), bytes("blocklisted")
            );
        }
    }

    function _isBlocked(
        address who
    ) internal view returns (bool) {
        return blocked && who == BLOCKABLE;
    }

    function _asColl(
        address holder,
        bytes memory data
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(holder);
        LOCK.acquire();
        vm.prank(COLL);
        (ok, ret) = address(VAULT).call(data);
        vm.prank(holder);
        LOCK.release();
    }

    /// @dev An open position chosen by `seed`, or zero when there is none.
    function _openKey(
        uint256 seed
    ) internal view returns (bytes32) {
        uint256 n = keys.length;
        for (uint256 i = 0; i < n; ++i) {
            bytes32 key = keys[(seed % n + i) % n];
            if (isOpen[key]) return key;
        }
        return bytes32(0);
    }

    /// @dev An open position with units and a number of them; `Skipped` when there is none.
    function _pickUnits(
        uint256 keySeed,
        uint256 unitsSeed,
        bool preferBlocked
    ) internal view returns (bytes32 key, uint128 units) {
        uint256 n = keys.length;
        // While the blocklist is on, the blocklisted depositor's positions come first, so the fallback is reached.
        for (uint256 pass = blocked && preferBlocked ? 0 : 1; pass < 2; ++pass) {
            for (uint256 i = 0; i < n; ++i) {
                key = keys[(keySeed % n + i) % n];
                if (!isOpen[key] || (pass == 0 && depositorOfKey[key] != BLOCKABLE)) continue;
                uint128 held = VAULT.unitsOf(key);
                if (held == 0) continue;
                // Bounded by the position's units, so it fits uint128.
                // forge-lint: disable-next-line(unsafe-typecast)
                return (key, uint128(bound(unitsSeed, 1, held)));
            }
        }
        revert Skipped();
    }

    function _owedAll() internal view returns (uint256[2][] memory o) {
        uint256 n = keys.length;
        o = new uint256[2][](n);
        for (uint256 i = 0; i < n; ++i) {
            if (isOpen[keys[i]]) (o[i][0], o[i][1]) = owed(keys[i]);
        }
    }

    function _accrueFrom(
        uint256[2][] memory before
    ) internal {
        for (uint256 i = 0; i < before.length; ++i) {
            bytes32 key = keys[i];
            if (!isOpen[key]) continue;
            (uint256 n0, uint256 n1) = owed(key);
            if (n0 < before[i][0] || n1 < before[i][1]) {
                ++owedFell;
                continue;
            }
            _credit(_accrued, key, n0 - before[i][0], n1 - before[i][1]);
        }
    }

    function _credit(
        mapping(bytes32 => uint256[2]) storage ledger,
        bytes32 key,
        uint256 a0,
        uint256 a1
    ) internal {
        ledger[key][0] += a0;
        ledger[key][1] += a1;
    }

    function _snap() internal view returns (uint256[] memory s) {
        s = new uint256[](ACTORS * TOKENS);
        for (uint256 a = 0; a < ACTORS; ++a) {
            for (uint256 t = 0; t < TOKENS; ++t) {
                s[a * TOKENS + t] = IERC20(tokens[t]).balanceOf(actors[a]);
            }
        }
    }

    /// @dev What actor `a` received of token `t` since `s`; 0 if its balance fell.
    function _received(
        uint256[] memory s,
        uint256 a,
        uint256 t
    ) internal view returns (uint256) {
        uint256 b = IERC20(tokens[t]).balanceOf(actors[a]);
        return b > s[a * TOKENS + t] ? b - s[a * TOKENS + t] : 0;
    }

    /// @dev Everything every actor other than `skipA` and `skipB` received since `s`.
    function _othersReceived(
        uint256[] memory s,
        uint256 skipA,
        uint256 skipB
    ) internal view returns (uint256 total) {
        for (uint256 a = 0; a < ACTORS; ++a) {
            if (a == skipA || a == skipB) continue;
            for (uint256 t = 0; t < TOKENS; ++t) {
                total += _received(s, a, t);
            }
        }
    }

    /// @dev The fee part of a release to the depositor: what it received less the returned principal.
    function _feePart(
        uint256[] memory s,
        bytes32 key,
        address depositor,
        uint256[] memory amounts
    ) internal view returns (uint256 f0, uint256 f1) {
        uint256 d = _actorIndex(depositor);
        uint256[2] memory t = tokenIdx[marketOfKey[key] - 1];
        uint256 r0 = _received(s, d, t[0]);
        uint256 r1 = _received(s, d, t[1]);
        f0 = r0 > amounts[0] ? r0 - amounts[0] : 0;
        f1 = r1 > amounts[1] ? r1 - amounts[1] : 0;
    }

    function _actorIndex(
        address who
    ) internal view returns (uint256) {
        for (uint256 a = 0; a < ACTORS; ++a) {
            if (actors[a] == who) return a;
        }
        return type(uint256).max;
    }

    /// @dev A PositionManager batch decreasing all of the position's liquidity and taking it to the attacker.
    function _drain(
        bytes32 key
    ) internal view returns (bytes memory) {
        uint256 i = marketOfKey[key] - 1;
        (uint128 liq,,) = STATE_VIEW.getPositionInfo(poolIds[i], address(POSM), lowers[i], uppers[i], key);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(uint256(key), uint256(liq), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(poolKeys[i].currency0, poolKeys[i].currency1, ATTACKER);
        return abi.encode(abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR), params);
    }

    function _slot0(
        bytes32 id
    ) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,) = IV4StateViewSlot0(address(STATE_VIEW)).getSlot0(id);
    }
}

interface IV4StateViewSlot0 {
    function getSlot0(
        bytes32 poolId
    ) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}
