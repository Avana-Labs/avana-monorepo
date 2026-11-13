// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracleCLModuleCaller} from "./LPOracleCLModuleCaller.sol";
import {LPOracleCLPool} from "./LPOracleCLPool.sol";
import {LPOracleLogicBase} from "./LPOracleLogicBase.sol";
import {Evaluation} from "./LPOracleTypes.sol";
import {LPOracleViewLogic} from "./LPOracleViewLogic.sol";
import {ClPriceStateView} from "./types/ClPriceStateView.sol";

/// @title LPOracleCLViewLogic
/// @notice The evaluation views of the concentrated-liquidity LPOracle and its extension view `getClPriceState()`,
/// run by delegatecall from `LPOracleCL` (2.10 Views and freshness exposure).
/// @dev `getClPriceState()` runs the same evaluation as `latestAnswer()` in the block and adds the module's detail:
/// the oracle and clamped square-root prices of the valuation prices, the pool's mean tick against the tick of the
/// uncapped quotes, the tolerance and the observation cardinality (`REQ-ORACLE-104`).
/// @custom:spec REQ-ORACLE-042, REQ-ORACLE-080, REQ-ORACLE-104
// Its `latestRoundData` is the LPOracle's Chainlink-compatible view, not a sequencer-uptime feed.
// forge-lint: disable-next-line(missing-inheritance)
contract LPOracleCLViewLogic is LPOracleViewLogic, LPOracleCLModuleCaller {
    /// @notice Fixes the chain constants, the `slot0` layout and the module contract; they must equal the
    /// implementation's.
    /// @custom:spec REQ-ORACLE-080
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

    /// @notice Concentrated-liquidity detail of the current evaluation (`ILPOracleCL.getClPriceState`).
    /// @custom:spec REQ-ORACLE-042, REQ-ORACLE-104, REQ-AMM-V3-005, REQ-AMM-SLIP-005
    // The body of the `ILPOracleCL` selector that `LPOracleCL` declares and forwards here; this logic contract does not
    // inherit `ILPOracleCL`, whose `MODULE_LOGIC` the implementation serves itself.
    // solhint-disable-next-line comprehensive-interface
    function getClPriceState() external view returns (ClPriceStateView memory report) {
        Evaluation memory e = _evaluate(false);
        report = _clReportOf(!e.failed, e.quotes, e.prices, e.cfg.twapWindow, e.cfg.consistencyToleranceBps);
    }
}
