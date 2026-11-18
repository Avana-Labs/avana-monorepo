// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SecondSource} from "../../types/SecondSource.sol";
import {LPOracleCLModule} from "./LPOracleCLModule.sol";
import {LPOracleCLPool} from "./LPOracleCLPool.sol";
import {LPOracleStorage} from "./LPOracleStorage.sol";
import {ClPriceStateView} from "./types/ClPriceStateView.sol";

/// @title LPOracleCLModuleLogic
/// @notice The concentrated-liquidity pricing module as one immutable logic contract, run by delegatecall.
/// @dev Holds no state; every entry point reverts `NotDelegated` unless delegated.
// Its `logicConfig()` is the logic contracts' chain-constant hash, not the ParameterStore's logic view.
// Its functions are pricing hooks called only by delegatecall from the logic contracts; no interface declares them.
// solhint-disable comprehensive-interface
// forge-lint: disable-next-line(missing-inheritance)
contract LPOracleCLModuleLogic is LPOracleCLModule {
    /// @dev This contract's own address, to detect a non-delegated call.
    address private immutable _SELF;

    /// @notice Sets the chain constants and the `slot0` layout; they must equal the implementation's.
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

    /// @notice Identifier the logic contracts check at construction.
    function MODULE_ID() external pure virtual returns (bytes32 id) {
        id = keccak256("avana.LPOracleCLModuleLogic.v1");
    }

    /// @notice Hash of the chain constants, as every LPOracle logic contract reports it.
    function logicConfig() external view returns (bytes32 config) {
        config = keccak256(
            abi.encode(_TIMELOCK, _CHAIN_BLOCK_TIME, _POKE_MIN_GAS_FLOOR, _POKE_MIN_GAS_CEILING, _HAS_SEQUENCER)
        );
    }

    /// @notice The composition hook at the price vector `(p0, p1)`.
    function composition(
        uint256 units,
        uint256 p0,
        uint256 p1
    ) external view onlyDelegated returns (bool ok, uint256 a0, uint256 a1) {
        uint256[] memory amounts;
        (ok, amounts) = _composition(units, _pair(p0, p1));
        if (ok) (a0, a1) = (amounts[0], amounts[1]);
    }

    /// @notice The pool hook on the quotes `(q0, q1)` and the valuation prices `(v0, v1)`.
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

    function isOwnPool(
        bytes32 poolRef
    ) external view onlyDelegated returns (bool own) {
        own = _isOwnPool(poolRef);
    }

    /// @notice The listing-check hook at the quotes `(q0, q1)`.
    function listingChecks(
        ClListingInputs calldata x,
        uint256 q0,
        uint256 q1
    ) external view onlyDelegated returns (uint256 failedChecks) {
        failedChecks = _clListingChecks(x, _pair(q0, q1));
    }

    /// @notice The concentrated-liquidity report of `getClPriceState()`.
    function clReport(
        bool priced,
        uint256[] calldata quotes,
        uint256[] calldata prices,
        uint32 window,
        uint16 toleranceTicks
    ) external view onlyDelegated returns (ClPriceStateView memory report) {
        report = _clReport(priced, quotes, prices, window, toleranceTicks);
    }

    function _pair(
        uint256 a,
        uint256 b
    ) private pure returns (uint256[] memory v) {
        v = new uint256[](2);
        (v[0], v[1]) = (a, b);
    }
}
