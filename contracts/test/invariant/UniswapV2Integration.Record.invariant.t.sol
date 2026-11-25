// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV2Integration} from "../../src/integrations/UniswapV2Integration.sol";
import {UniswapV2Positions} from "../../src/integrations/UniswapV2Positions.sol";
import {UniswapV2TestBase} from "../utils/UniswapV2TestBase.sol";
import {MockUniswapV2Factory, MockUniswapV2Pair} from "../utils/mocks/UniswapV2Mocks.sol";
import {MintableToken} from "../utils/mocks/UniswapV3Mocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Drives the Uniswap v2 LPVault's record of each pledged position's LP: pledges, top-ups through the vault,
/// LP sent straight into a pledged position through the wrapper's open `increase`, partial and full removals and
/// unwinds, swaps, and the v2 protocol fee switched on and off with mints and burns that realize it.
contract UniswapV2RecordHandler is Test {
    /// @dev Storage slot of `UniswapV2Integration._recordLp` (forge inspect … storageLayout).
    uint256 internal constant RECORD_SLOT = 5;
    uint256 internal constant MAX_KEYS = 6;

    UniswapV2Integration internal immutable VAULT;
    UniswapV2Positions internal immutable POSITIONS;
    MockUniswapV2Factory internal immutable FACTORY;
    MockUniswapV2Pair internal immutable PAIR;
    MintableToken internal immutable T0;
    MintableToken internal immutable T1;
    address internal immutable ADAPTER;
    address internal immutable ACCOUNT;

    address internal constant OWNER = address(0xB0B);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant FEE_TO = address(0xFEE);
    address internal constant RECIPIENT = address(0xCAFE);

    bytes32[] public keys;
    /// @dev The LP each key's record should hold: what it pledged, plus its top-ups, less what Avana burned from it.
    mapping(bytes32 => uint256) public expectedRecord;
    /// @dev LP sent into each key's NFT outside Avana; never Avana's to burn.
    mapping(bytes32 => uint256) public directLp;

    /// @dev Unwinds or removals that burned more than the record or than its share `rec · l / (rest + l)`.
    uint256 public overBurns;
    uint256[9] public hits;

    constructor(
        UniswapV2Integration vault,
        UniswapV2Positions positions,
        MockUniswapV2Factory factory,
        MockUniswapV2Pair pair,
        address adapter,
        address account
    ) {
        (VAULT, POSITIONS, FACTORY, PAIR, ADAPTER, ACCOUNT) = (vault, positions, factory, pair, adapter, account);
        T0 = MintableToken(pair.token0());
        T1 = MintableToken(pair.token1());
        vm.prank(OWNER);
        positions.setApprovalForAll(address(vault), true);
        vm.startPrank(OWNER);
        T0.approve(address(vault), type(uint256).max);
        T1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function keyCount() external view returns (uint256) {
        return keys.length;
    }

    function recordOf(
        bytes32 key
    ) public view returns (uint256) {
        return uint256(vm.load(address(VAULT), keccak256(abi.encode(uint256(key), RECORD_SLOT))));
    }

    function held(
        bytes32 key
    ) public view returns (uint256 lp) {
        (, lp) = POSITIONS.positions(uint256(key));
    }

    // ─── Actions ───

    /// @dev Pledges fresh LP, or (`fromStock`) LP the owner minted earlier, which can predate a fee switch-off: a mint
    /// clears a stale `kLast` with the fee off, so only stocked LP reaches a pledge read against a stale `kLast`.
    function pledge(
        uint256 a0,
        uint256 ratioBps,
        bool fromStock
    ) external {
        if (keys.length >= MAX_KEYS) return;
        uint256 lp;
        if (fromStock && PAIR.balanceOf(OWNER) != 0) {
            lp = PAIR.balanceOf(OWNER) / 2 + 1;
        } else {
            a0 = bound(a0, 1e15, 1e23);
            lp = _mintLp(OWNER, a0, a0 * bound(ratioBps, 5000, 20_000) / 10_000);
        }
        if (lp == 0) return;
        vm.startPrank(OWNER);
        PAIR.approve(address(POSITIONS), lp);
        bytes32 key = bytes32(POSITIONS.wrap(address(PAIR), lp, OWNER));
        vm.stopPrank();
        vm.prank(ADAPTER);
        VAULT.pledge(OWNER, ACCOUNT, 1, key);
        keys.push(key);
        expectedRecord[key] = lp;
        ++hits[0];
    }

    /// @dev LP the owner holds unwrapped, for a later pledge.
    function stockLp(
        uint256 a0
    ) external {
        (uint112 r0, uint112 r1,) = PAIR.getReserves();
        a0 = bound(a0, 1e15, 1e23);
        if (_mintLp(OWNER, a0, a0 * r1 / r0 + 1) != 0) ++hits[8];
    }

    function topUp(
        uint256 i,
        uint256 a0,
        uint256 a1
    ) external {
        if (keys.length == 0) return;
        bytes32 key = keys[i % keys.length];
        if (VAULT.getPosition(key).liquidity == 0) return;
        a0 = bound(a0, 1e12, 1e22);
        a1 = bound(a1, 1e12, 1e22);
        T0.mint(OWNER, a0);
        T1.mint(OWNER, a1);
        uint256 before = held(key);
        vm.prank(ADAPTER);
        try VAULT.addLiquidity(key, OWNER, a0, a1, 0, 0) {
            expectedRecord[key] += held(key) - before;
            ++hits[1];
        } catch {
            // A top-up too small to mint any LP is refused by the pair; nothing changed.
        }
    }

    /// @dev The attacker's LP, sent into a pledged position by the wrapper's open `increase`.
    function directIncrease(
        uint256 i,
        uint256 a0
    ) external {
        if (keys.length == 0) return;
        bytes32 key = keys[i % keys.length];
        a0 = bound(a0, 1e12, 1e22);
        (uint112 r0, uint112 r1,) = PAIR.getReserves();
        uint256 lp = _mintLp(ATTACKER, a0, a0 * r1 / r0 + 1);
        if (lp == 0) return;
        vm.startPrank(ATTACKER);
        PAIR.approve(address(POSITIONS), lp);
        uint256 received = POSITIONS.increase(uint256(key), lp);
        vm.stopPrank();
        directLp[key] += received;
        ++hits[2];
    }

    function unwind(
        uint256 i,
        uint256 partBps
    ) external {
        if (keys.length == 0) return;
        bytes32 key = keys[i % keys.length];
        uint128 credit = VAULT.getPosition(key).credit;
        if (credit == 0) return;
        uint128 c = uint128(Math.max(1, uint256(credit) * bound(partBps, 1, 10_000) / 10_000));
        (uint256 rec, uint256 before, uint128 liqBefore) = (recordOf(key), held(key), VAULT.getPosition(key).liquidity);
        (uint256 rootK, uint256 supply) = _pairState();
        vm.prank(ADAPTER);
        try VAULT.unwind(key, c, 0, 0, RECIPIENT) {
            _afterBurn(key, rec, before, liqBefore, rootK, supply);
            ++hits[3];
        } catch {}
    }

    function removeLiquidity(
        uint256 i,
        uint256 partBps
    ) external {
        if (keys.length == 0) return;
        bytes32 key = keys[i % keys.length];
        uint128 liq = VAULT.getPosition(key).liquidity;
        if (liq == 0) return;
        uint128 l = uint128(Math.max(1, uint256(liq) * bound(partBps, 1, 10_000) / 10_000));
        (uint256 rec, uint256 before) = (recordOf(key), held(key));
        (uint256 rootK, uint256 supply) = _pairState();
        vm.prank(ADAPTER);
        try VAULT.removeLiquidity(key, l, 0, 0, OWNER) {
            _afterBurn(key, rec, before, liq, rootK, supply);
            ++hits[4];
        } catch {}
    }

    function swap(
        bool zeroForOne,
        uint256 amountIn
    ) external {
        (uint112 r0, uint112 r1,) = PAIR.getReserves();
        (uint256 rIn, uint256 rOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        amountIn = bound(amountIn, 1e9, rIn);
        uint256 out = amountIn * 997 * rOut / (rIn * 1000 + amountIn * 997);
        if (out == 0) return;
        (zeroForOne ? T0 : T1).mint(address(PAIR), amountIn);
        PAIR.swap(zeroForOne ? 0 : out, zeroForOne ? out : 0, address(this), "");
        ++hits[5];
    }

    function setFee(
        bool on
    ) external {
        FACTORY.setFeeTo(on ? FEE_TO : address(0));
        ++hits[6];
    }

    /// @dev A third party's mint or burn, which mints the pending protocol fee (fee on) or clears `kLast` (fee off).
    function thirdPartyMintOrBurn(
        bool burn,
        uint256 a0
    ) external {
        uint256 mine = PAIR.balanceOf(address(this));
        if (burn && mine > 1) {
            PAIR.transfer(address(PAIR), mine / 2);
            try PAIR.burn(address(this)) {} catch {}
        } else {
            (uint112 r0, uint112 r1,) = PAIR.getReserves();
            a0 = bound(a0, 1e12, 1e22);
            _mintLp(address(this), a0, a0 * r1 / r0 + 1);
        }
        ++hits[7];
    }

    // ─── Internal ───

    /// @dev The pair's √k and its supply with the pending protocol fee counted (v2-core's `_mintFee`, as if on).
    function _pairState() internal view returns (uint256 rootK, uint256 supply) {
        (uint112 r0, uint112 r1,) = PAIR.getReserves();
        rootK = Math.sqrt(uint256(r0) * r1);
        supply = PAIR.totalSupply();
        uint256 rootKLast = Math.sqrt(PAIR.kLast());
        if (rootKLast != 0 && rootK > rootKLast) supply += supply * (rootK - rootKLast) / (rootK * 5 + rootKLast);
    }

    /// @dev Counts a burn over the record, over the record's share `⌊rec · removed / (rest + removed)⌋` of the
    /// liquidity removed (so the record left always covers at least its share `rec · rest / (rest + removed)` of the
    /// liquidity still pledged, over any number of partial unwinds), or (#382) over the LP that held the removed
    /// liquidity at the pair's state before the call (rounded up), which would take the position's fee growth.
    function _afterBurn(
        bytes32 key,
        uint256 rec,
        uint256 before,
        uint128 liqBefore,
        uint256 rootK,
        uint256 supply
    ) internal {
        uint256 burned = before - held(key);
        uint128 removed = liqBefore - VAULT.getPosition(key).liquidity;
        uint256 rest = liqBefore - removed;
        if (
            burned > rec || burned * (rest + removed) > rec * removed
                || (rootK != 0 && burned > Math.mulDiv(removed, supply, rootK, Math.Rounding.Ceil))
        ) {
            ++overBurns;
        }
        expectedRecord[key] -= Math.min(burned, expectedRecord[key]);
    }

    function _mintLp(
        address to,
        uint256 a0,
        uint256 a1
    ) internal returns (uint256 lp) {
        T0.mint(address(PAIR), a0);
        T1.mint(address(PAIR), a1);
        try PAIR.mint(to) returns (uint256 minted) {
            lp = minted;
        } catch {
            PAIR.skim(address(this));
        }
    }
}

/// @notice Invariants of the v2 record over any sequence of the handler's actions. They name the bugs of PR #367 and
/// #374: an unwind that burns LP sent into the position outside Avana or more than the record's share, and a credit
/// read with the fee off that exceeds the record's liquidity once the fee is on.
contract UniswapV2IntegrationRecordInvariantTest is UniswapV2TestBase {
    UniswapV2RecordHandler internal handler;

    function setUp() public {
        _deploy(address(new MintableToken("A", 18)), address(new MintableToken("B", 18)), 1000e18, 1000e18);
        handler = new UniswapV2RecordHandler(vault, positions, factory, pair, adapter, account);
        targetContract(address(handler));
    }

    /// @notice Bug hunted: a record that drifts from what the position pledged and topped up, less what Avana burned.
    function invariant_recordIsPledgedPlusTopUpsLessBurns() public view {
        for (uint256 i; i < handler.keyCount(); ++i) {
            bytes32 key = handler.keys(i);
            assertEq(handler.recordOf(key), handler.expectedRecord(key), "record drifted");
        }
    }

    /// @notice Bug hunted: an unwind or removal that burns LP sent into the NFT outside Avana. The NFT holds the
    /// record plus that LP, at all times.
    function invariant_directLpIsNeverBurned() public view {
        for (uint256 i; i < handler.keyCount(); ++i) {
            bytes32 key = handler.keys(i);
            assertEq(handler.held(key), handler.recordOf(key) + handler.directLp(key), "direct LP burned");
        }
    }

    /// @notice Bug hunted: a burn larger than the record, than the record's share of the liquidity removed, or than the
    /// LP holding that liquidity now, which would hand the position's v2 fee growth to the liquidator (#382).
    function invariant_unwindNeverBurnsMoreThanTheRecordShare() public view {
        assertEq(handler.overBurns(), 0);
    }

    /// @notice Bug hunted: a credit above the liquidity of the record's LP. The liquidity is read with the protocol fee
    /// pending since `kLast` minted, whether `feeTo` is on or off: what the LP is worth after the next mint or burn
    /// with the fee switched on (v2-core's `_mintFee`, which floors the fee).
    /// @dev The reference is the exact worth `rec · √k / supply` rounded up. The integer read `⌊√k⌋ · rec / supply`
    /// (the vault's `liquidityOf`) is not monotone at the last wei: after a partial burn it can sit up to `rec / supply`
    /// (at most 1) below a credit that the exact worth still covers.
    function invariant_creditNeverAboveTheRecordsLiquidityFeeOnOrOff() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 k = uint256(r0) * r1;
        uint256 supply = pair.totalSupply();
        uint256 rootK = Math.sqrt(k);
        uint256 rootKLast = Math.sqrt(pair.kLast());
        if (rootKLast != 0 && rootK > rootKLast) supply += supply * (rootK - rootKLast) / (rootK * 5 + rootKLast);
        uint256 rootKUp = Math.sqrt(k, Math.Rounding.Ceil);
        for (uint256 i; i < handler.keyCount(); ++i) {
            bytes32 key = handler.keys(i);
            uint256 worth = Math.mulDiv(handler.recordOf(key), rootKUp, supply, Math.Rounding.Ceil);
            assertLe(vault.getPosition(key).credit, worth, "credit above the record's liquidity");
        }
    }

    /// @notice The campaign reaches every action: a fixed sequence lands each once, so a handler whose calls all
    /// return early shows up here.
    function test_handlerLandsEveryAction() public {
        handler.setFee(true);
        handler.stockLp(1e20);
        handler.swap(true, 1e20);
        handler.setFee(false);
        handler.pledge(0, 0, true);
        // The stocked LP is read against the stale kLast of the fee that was on when it was minted.
        invariant_creditNeverAboveTheRecordsLiquidityFeeOnOrOff();
        handler.pledge(1e20, 10_000, false);
        handler.setFee(true);
        handler.swap(true, 1e20);
        handler.topUp(1, 1e19, 1e19);
        handler.directIncrease(1, 1e19);
        handler.thirdPartyMintOrBurn(false, 1e19);
        handler.swap(false, 1e20);
        handler.unwind(1, 2500);
        handler.removeLiquidity(1, 2500);
        handler.thirdPartyMintOrBurn(true, 0);
        handler.removeLiquidity(1, 10_000);
        for (uint256 k; k < 9; ++k) {
            assertGt(handler.hits(k), 0, "an action never landed");
        }
        invariant_recordIsPledgedPlusTopUpsLessBurns();
        invariant_directLpIsNeverBurned();
        invariant_unwindNeverBurnsMoreThanTheRecordShare();
        invariant_creditNeverAboveTheRecordsLiquidityFeeOnOrOff();
        // A full removal burns only the LP that held the liquidity: the fee growth from the swaps stays in the record
        // and goes back with the NFT (#382).
        assertEq(vault.getPosition(handler.keys(1)).liquidity, 0);
        assertGt(handler.recordOf(handler.keys(1)), 0, "the fee growth left the position");
    }
}
