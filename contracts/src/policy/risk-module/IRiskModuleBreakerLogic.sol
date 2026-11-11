// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";

/// @title IRiskModuleBreakerLogic
/// @notice Breaker conditions and states of markets and debt reserves (SPEC-BRK-002 to SPEC-BRK-008).
interface IRiskModuleBreakerLogic is IRiskModuleLogic {
    /// @notice Market reasons holding now from live state: `ORACLE`, `POOL_SHARE`, `POOL_DEPTH`, `ISSUER`, `CONFIG_DRIFT`.
    /// @param marketId The market.
    /// @param unitsGiven True when `poolUnits` is the pool's credited units (inside a pledge); false reads
    /// `Collateralization.poolUnits`.
    /// @param poolUnits Avana's credited units in every market of the pool, when given.
    /// @return live Bitmap of `BreakerReasons`.
    /// @custom:spec REQ-RISK-065, REQ-RISK-091, SPEC-BRK-002, SPEC-BRK-003
    function marketConditions(
        uint256 marketId,
        bool unitsGiven,
        uint256 poolUnits
    ) external view returns (uint32 live);

    /// @notice Debt reasons holding now from live state: `DEFICIT` and `ISSUER`.
    /// @param spoke The CDP Spoke.
    /// @param debtReserveId The debt reserve.
    /// @return live Bitmap of `BreakerReasons`.
    /// @custom:spec REQ-RISK-091, SPEC-BRK-003, SPEC-BRK-004
    function debtConditions(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32 live);

    /// @notice Tripped reasons of a market breaker: live, recovering (every temporary bit while inside
    /// `gateRecoverySeconds` of the last recorded breach) and latched, and when the last temporary gate reopens.
    /// @param marketId The market.
    /// @param unitsGiven As `marketConditions`.
    /// @param poolUnits As `marketConditions`.
    /// @return reasons Bitmap of `BreakerReasons`.
    /// @return reopensAt Reopening time of the temporary gates, 0 when none holds or recovers.
    /// @custom:spec REQ-RISK-065, SPEC-BRK-007, SPEC-BRK-008
    function marketBreaker(
        uint256 marketId,
        bool unitsGiven,
        uint256 poolUnits
    ) external view returns (uint32 reasons, uint64 reopensAt);

    /// @notice Tripped reasons of a debt breaker: live `DEFICIT` and `ISSUER`, recovering and latched.
    /// @param spoke The CDP Spoke.
    /// @param debtReserveId The debt reserve.
    /// @return reasons Bitmap of `BreakerReasons`.
    /// @return reopensAt Reopening time of the temporary gates, 0 when none recovers.
    /// @custom:spec REQ-RISK-065, SPEC-BRK-004, SPEC-BRK-007, SPEC-BRK-008
    function debtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32 reasons, uint64 reopensAt);
}
