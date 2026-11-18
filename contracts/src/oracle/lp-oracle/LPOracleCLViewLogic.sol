// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracleCLModuleCaller} from "./LPOracleCLModuleCaller.sol";
import {LPOracleCLPool} from "./LPOracleCLPool.sol";
import {LPOracleLogicBase} from "./LPOracleLogicBase.sol";
import {ClPriceStateView, Evaluation} from "./LPOracleTypes.sol";
import {LPOracleViewLogic} from "./LPOracleViewLogic.sol";

/// @title LPOracleCLViewLogic
/// @notice Evaluation views of the concentrated-liquidity LPOracle, including `getClPriceState()`, run by delegatecall.
// Its `latestRoundData` is the LPOracle's Chainlink-compatible view, not a sequencer-uptime feed.
// forge-lint: disable-next-line(missing-inheritance)
contract LPOracleCLViewLogic is LPOracleViewLogic, LPOracleCLModuleCaller {
    /// @notice Sets the chain constants, `slot0` layout and module contract; they must match the implementation.
    constructor(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer,
        uint8 slot0Words,
        address moduleLogic
    )
        LPOracleLogicBase(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer)
        LPOracleCLPool(slot0Words)
        LPOracleCLModuleCaller(moduleLogic)
    {}

    /// @notice Concentrated-liquidity detail of the current evaluation.
    // Body of the `ILPOracleCL` selector that `LPOracleCL` forwards here; this contract does not inherit `ILPOracleCL`.
    // solhint-disable-next-line comprehensive-interface
    function getClPriceState() external view returns (ClPriceStateView memory report) {
        Evaluation memory e = _evaluate(false);
        report = _clReportOf(!e.failed, e.quotes, e.prices, e.cfg.twapWindow, e.cfg.consistencyToleranceBps);
    }
}
