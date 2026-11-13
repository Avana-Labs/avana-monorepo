// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../../src/amm/IAmmIntegration.sol";
import {IClIntegration} from "../../../src/amm/IClIntegration.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice What the custody handler needs from the suite that runs it: minting on the fixture's position managers
/// and pools, and moving a market's pool.
interface IClCustodySource {
    function cMintFor(
        uint256 marketId,
        address owner,
        uint128 liquidity
    ) external returns (bytes32 key);

    function cManagerOf(
        bytes32 key
    ) external view returns (address manager);

    function cTokenIdOf(
        bytes32 key
    ) external pure returns (uint256 tokenId);

    function cIncreaseLiquidity(
        bytes32 key,
        uint128 liquidity
    ) external;

    function cAccrue(
        bytes32 key,
        uint128 amount0,
        uint128 amount1
    ) external;

    function cMovePool(
        uint256 marketId,
        int24 tick,
        uint128 outsideLiquidity
    ) external;
}

/// @title ClLPVaultCustodyHandler
/// @notice Actor handler of the concentrated-liquidity LPVault custody suites (TEST-084, TEST-215 on the LPVault):
/// depositors pledge, partly remove, collect fees and withdraw through Collateralization under the AaveAdapter's Lock;
/// LPVaultSwap seizes and Collateralization reconciles units; a third party adds liquidity to custodied positions; an
/// attacker pushes or sends NFTs to the LPVault, names itself in fee collections and calls every custody function
/// directly under either Lock member's session; the timelock returns strays to their senders; the pool's spot price and
/// outside liquidity move. Ghosts track each position's depositor, market and credited units as Collateralization
/// would, each stray's sender, what LPVaultSwap was reported and received, and every call that should have failed.
contract ClLPVaultCustodyHandler is CommonBase, StdUtils {
    uint256 internal constant MAX_POSITIONS = 10;
    uint256 internal constant MAX_STRAYS = 4;

    IClIntegration public immutable VAULT;
    IClCustodySource public immutable SOURCE;
    Lock public immutable LOCK;
    address public immutable ADAPTER;
    address public immutable COLL;
    address public immutable SWAP;
    address public immutable TIMELOCK;
    address public immutable ATTACKER;
    address[2] internal depositors;

    bytes32[] public keys;
    mapping(bytes32 key => address depositor) public depositorOfKey;
    mapping(bytes32 key => uint256 marketId) public marketOfKey;
    mapping(bytes32 key => uint128 units) public credited;
    mapping(bytes32 key => bool open) public isOpen;

    bytes32[] public strays;
    mapping(bytes32 key => address sender) public senderOf;
    mapping(bytes32 key => bool returned) public strayReturned;

    /// @notice Pool tokens LPVaultSwap was reported and actually received across all seizures, per market token.
    uint256[2] public swapReported;
    uint256[2] public swapReceived;
    /// @notice Calls that must fail and succeeded: a direct custody call, a fee collection naming anyone but the
    /// depositor, a stray return of a custodied position.
    uint256 public forbiddenSuccesses;

    constructor(
        IClIntegration vault,
        IClCustodySource source,
        Lock lock,
        address[5] memory roles,
        address[2] memory depositors_
    ) {
        (VAULT, SOURCE, LOCK) = (vault, source, lock);
        (ADAPTER, COLL, SWAP, TIMELOCK, ATTACKER) = (roles[0], roles[1], roles[2], roles[3], roles[4]);
        depositors = depositors_;
    }

    function keyCount() external view returns (uint256) {
        return keys.length;
    }

    function strayCount() external view returns (uint256) {
        return strays.length;
    }

    // ─── Depositors ───

    function pledge(
        uint256 who,
        uint256 marketSeed,
        uint128 liquidity
    ) external {
        if (keys.length >= MAX_POSITIONS) return;
        address owner = depositors[who % 2];
        uint256 marketId = 1 + marketSeed % 2;
        bytes32 key = SOURCE.cMintFor(marketId, owner, uint128(bound(liquidity, 1e12, 1e15)));
        (bool ok, bytes memory ret) =
            _asColl(ADAPTER, abi.encodeCall(IAmmIntegration.receivePosition, (marketId, owner, key)));
        require(ok, "pledge");
        keys.push(key);
        (depositorOfKey[key], marketOfKey[key], credited[key], isOpen[key]) =
        (owner, marketId, abi.decode(ret, (uint128)), true);
    }

    function partialRemoval(
        uint256 keySeed,
        uint256 unitsSeed
    ) external {
        (bytes32 key, uint128 units) = _pickUnits(keySeed, unitsSeed);
        if (units == 0) return;
        (bool ok,) =
            _asColl(ADAPTER, abi.encodeCall(IAmmIntegration.releaseToDepositor, (key, units, new uint256[](2))));
        require(ok, "partial removal");
        credited[key] -= units;
    }

    function collect(
        uint256 keySeed,
        bool nameAttacker
    ) external {
        bytes32 key = _openKey(keySeed);
        if (key == bytes32(0)) return;
        address named = nameAttacker ? ATTACKER : depositorOfKey[key];
        (bool ok,) = _asColl(ADAPTER, abi.encodeCall(IAmmIntegration.collectFees, (key, named)));
        if (nameAttacker && ok) ++forbiddenSuccesses;
        if (!nameAttacker) require(ok, "fee collection");
    }

    function withdraw(
        uint256 keySeed
    ) external {
        bytes32 key = _openKey(keySeed);
        if (key == bytes32(0)) return;
        (bool ok,) = _asColl(ADAPTER, abi.encodeCall(IAmmIntegration.returnPosition, (key)));
        require(ok, "withdraw");
        (isOpen[key], credited[key]) = (false, 0);
    }

    // ─── LPVaultSwap and Collateralization ───

    function seize(
        uint256 keySeed,
        uint256 unitsSeed
    ) external {
        (bytes32 key, uint128 units) = _pickUnits(keySeed, unitsSeed);
        if (units == 0) return;
        IERC20[2] memory t = _tokens(key);
        uint256 b0 = t[0].balanceOf(SWAP);
        uint256 b1 = t[1].balanceOf(SWAP);
        (bool ok, bytes memory ret) =
            _asColl(SWAP, abi.encodeCall(IAmmIntegration.unwind, (key, units, new uint256[](2), SWAP)));
        require(ok, "seizure");
        uint256[] memory amounts = abi.decode(ret, (uint256[]));
        swapReported[0] += amounts[0];
        swapReported[1] += amounts[1];
        swapReceived[0] += t[0].balanceOf(SWAP) - b0;
        swapReceived[1] += t[1].balanceOf(SWAP) - b1;
        credited[key] -= units;
    }

    function reconcile(
        uint256 keySeed,
        uint256 unitsSeed
    ) external {
        (bytes32 key, uint128 units) = _pickUnits(keySeed, unitsSeed);
        if (units == 0) return;
        (bool ok,) = _asColl(ADAPTER, abi.encodeCall(IAmmIntegration.unwind, (key, units, new uint256[](2), COLL)));
        require(ok, "reconcile");
        credited[key] -= units;
    }

    // ─── Third parties, attacker, pool and timelock ───

    function accrue(
        uint256 keySeed,
        uint128 a0,
        uint128 a1
    ) external {
        bytes32 key = _openKey(keySeed);
        if (key == bytes32(0)) return;
        SOURCE.cAccrue(key, uint128(bound(a0, 0, 1e9)), uint128(bound(a1, 0, 1e9)));
    }

    function donateLiquidity(
        uint256 keySeed,
        uint128 liquidity
    ) external {
        bytes32 key = _openKey(keySeed);
        if (key == bytes32(0)) return;
        SOURCE.cIncreaseLiquidity(key, uint128(bound(liquidity, 1, 1e14)));
    }

    function pushStray(
        uint128 liquidity,
        bool safe
    ) external {
        if (strays.length >= MAX_STRAYS) return;
        bytes32 key = SOURCE.cMintFor(1, ATTACKER, uint128(bound(liquidity, 1e9, 1e12)));
        IERC721 manager = IERC721(SOURCE.cManagerOf(key));
        uint256 id = SOURCE.cTokenIdOf(key);
        vm.prank(ATTACKER);
        if (safe) manager.safeTransferFrom(ATTACKER, address(VAULT), id);
        else manager.transferFrom(ATTACKER, address(VAULT), id);
        strays.push(key);
        senderOf[key] = ATTACKER;
    }

    function returnStray(
        uint256 seed,
        bool tryCustodied
    ) external {
        if (tryCustodied) {
            bytes32 key = _openKey(seed);
            if (key == bytes32(0)) return;
            vm.prank(TIMELOCK);
            (bool ok,) = address(VAULT).call(abi.encodeCall(VAULT.returnStray, (key, ATTACKER)));
            if (ok) ++forbiddenSuccesses;
            return;
        }
        if (strays.length == 0) return;
        bytes32 stray = strays[seed % strays.length];
        if (strayReturned[stray]) return;
        vm.prank(TIMELOCK);
        VAULT.returnStray(stray, senderOf[stray]);
        strayReturned[stray] = true;
    }

    /// @notice A custody call made directly by an attacker, the AaveAdapter, LPVaultSwap or the timelock (not through
    /// Collateralization) inside either Lock member's session: every one must fail.
    function attackDirect(
        uint256 keySeed,
        uint256 which,
        uint256 callerSeed,
        bool swapSession
    ) external {
        if (keys.length == 0) return;
        bytes32 key = keys[keySeed % keys.length];
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
        (bool ok,) = address(VAULT).call(calls[which % 5]);
        vm.prank(holder);
        LOCK.release();
        if (ok) ++forbiddenSuccesses;
    }

    function movePool(
        uint256 marketSeed,
        int24 tick,
        uint128 outside
    ) external {
        SOURCE.cMovePool(1 + marketSeed % 2, int24(bound(int256(tick), -4000, 4000)), outside);
    }

    // ─── Internal ───

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

    /// @dev An open position and a number of its credited units, 0 when it has none.
    function _pickUnits(
        uint256 keySeed,
        uint256 unitsSeed
    ) internal view returns (bytes32 key, uint128 units) {
        key = _openKey(keySeed);
        if (key == bytes32(0) || credited[key] == 0) return (key, 0);
        units = uint128(bound(unitsSeed, 1, credited[key]));
    }

    function _tokens(
        bytes32 key
    ) internal view returns (IERC20[2] memory t) {
        (,,, address[] memory tokens) = VAULT.marketOf(marketOfKey[key]);
        (t[0], t[1]) = (IERC20(tokens[0]), IERC20(tokens[1]));
    }
}
