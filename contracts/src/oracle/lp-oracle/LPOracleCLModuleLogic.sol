// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SecondSource} from "../../types/SecondSource.sol";
import {LPOracleCLModule} from "./LPOracleCLModule.sol";
import {LPOracleCLPool} from "./LPOracleCLPool.sol";
import {LPOracleStorage} from "./LPOracleStorage.sol";
import {ClPriceStateView} from "./types/ClPriceStateView.sol";

/// @title LPOracleCLModuleLogic
/// @notice The concentrated-liquidity pricing module as one immutable logic contract of the `LPOracleCL` implementation:
/// the poke, listing and view logic contracts run each pricing hook here by delegatecall, in the market proxy's storage
/// (2.10 Concentrated-liquidity pricing, Upgrade rules).
/// @dev Holds no state of its own and makes only static calls. Every entry point requires a delegated call
/// (`NotDelegated` otherwise), so called directly it never reads its own empty storage. The logic contracts fix its
/// address in an immutable at construction and require its `MODULE_ID()`, `SLOT0_WORDS()` and `logicConfig()` to match
/// theirs; the implementation requires all three logic contracts to name this same contract, so the pricing code of a
/// deployed implementation cannot be swapped except by an upgrade. Each hook keeps the gas guard of every pool read
/// (`SPEC-ORC-023`): a delegatecall forwards the caller's gas, and each read inside checks its own bound.
/// @custom:spec REQ-ORACLE-080, REQ-ORACLE-103, REQ-ORACLE-104, REQ-ORACLE-105, REQ-ORACLE-106, SPEC-ORC-023
contract LPOracleCLModuleLogic is LPOracleCLModule {
    /// @notice Identifier the logic contracts check at construction.
    bytes32 public constant MODULE_ID = keccak256("avana.LPOracleCLModuleLogic.v1");

    /// @dev This contract's own address: a call executing here, not in a proxy, is not delegated.
    address private immutable _SELF;

    /// @notice Fixes the chain constants and the `slot0` layout; they must equal the implementation's.
    /// @custom:spec REQ-ORACLE-080, REQ-AMM-V3-003, REQ-AMM-SLIP-003
    constructor(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer,
        uint8 slot0Words
    )
        LPOracleStorage(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer)
        LPOracleCLPool(slot0Words)
    {
        _SELF = address(this);
    }

    /// @dev Reverts `NotDelegated` when the call runs in this contract's own context.
    modifier onlyDelegated() {
        if (address(this) == _SELF) revert NotDelegated();
        _;
    }

    /// @notice `keccak256(abi.encode(TIMELOCK, CHAIN_BLOCK_TIME, POKE_MIN_GAS_FLOOR, POKE_MIN_GAS_CEILING,
    /// hasSequencer))`, as every LPOracle logic contract reports it.
    /// @custom:spec REQ-ORACLE-080
    function logicConfig() external view returns (bytes32 config) {
        config = keccak256(
            abi.encode(_TIMELOCK, _CHAIN_BLOCK_TIME, _POKE_MIN_GAS_FLOOR, _POKE_MIN_GAS_CEILING, _HAS_SEQUENCER)
        );
    }

    /// @notice The composition hook (`SPEC-ORC-006`) at the price vector `(p0, p1)`.
    /// @custom:spec SPEC-ORC-006, REQ-ORACLE-103
    function composition(
        uint256 units,
        uint256 p0,
        uint256 p1
    ) external view onlyDelegated returns (bool ok, uint256 a0, uint256 a1) {
        uint256[] memory amounts;
        (ok, amounts) = _composition(units, _pair(p0, p1));
        if (ok) (a0, a1) = (amounts[0], amounts[1]);
    }

    /// @notice The pool hook (`REQ-ORACLE-103`, `SPEC-ORC-010`, `REQ-ORACLE-104`) on the quotes `(q0, q1)` and the
    /// valuation prices `(v0, v1)`.
    /// @custom:spec REQ-ORACLE-103, SPEC-ORC-010, REQ-ORACLE-014, REQ-ORACLE-104
    function poolCheck(
        uint256 q0,
        uint256 q1,
        uint256 v0,
        uint256 v1,
        uint32 window,
        uint16 toleranceBps
    ) external view onlyDelegated returns (PoolCheck memory p) {
        p = _poolCheck(_pair(q0, q1), _pair(v0, v1), window, toleranceBps);
    }

    /// @notice The `PoolTwap` second-source hook (`SPEC-ORC-020`).
    /// @custom:spec SPEC-ORC-020, REQ-ORACLE-100
    function poolTwapPrice(
        uint256 index,
        bytes32 poolRef,
        uint32 twapWindow,
        uint256 q0,
        uint256 q1
    ) external view onlyDelegated returns (bool ok, uint256 value) {
        SecondSource memory source;
        (source.poolRef, source.twapWindow) = (poolRef, twapWindow);
        (ok, value) = _poolTwapPrice(index, source, _pair(q0, q1));
    }

    /// @notice The own-pool hook (`REQ-ORACLE-100`).
    /// @custom:spec REQ-ORACLE-100, REQ-ORACLE-046
    function isOwnPool(
        bytes32 poolRef
    ) external view onlyDelegated returns (bool own) {
        own = _isOwnPool(poolRef);
    }

    /// @notice The listing-check hook (`REQ-ORACLE-105`) at the quotes `(q0, q1)`.
    /// @custom:spec REQ-ORACLE-105, REQ-ORACLE-055, REQ-AMM-CORE-004
    function listingChecks(
        ClListingInputs calldata x,
        uint256 q0,
        uint256 q1
    ) external view onlyDelegated returns (uint256 failedChecks) {
        failedChecks = _clListingChecks(x, _pair(q0, q1));
    }

    /// @notice The concentrated-liquidity report of `getClPriceState()` (`REQ-ORACLE-104`).
    /// @custom:spec REQ-ORACLE-042, REQ-ORACLE-104
    function clReport(
        bool priced,
        uint256[] calldata quotes,
        uint256[] calldata prices,
        uint32 window,
        uint16 toleranceTicks
    ) external view onlyDelegated returns (ClPriceStateView memory report) {
        report = _clReport(priced, quotes, prices, window, toleranceTicks);
    }

    /// @dev `[a, b]`.
    function _pair(
        uint256 a,
        uint256 b
    ) private pure returns (uint256[] memory v) {
        v = new uint256[](2);
        (v[0], v[1]) = (a, b);
    }
}
