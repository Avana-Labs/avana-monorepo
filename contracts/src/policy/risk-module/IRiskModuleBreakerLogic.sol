// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";

/// @title IRiskModuleBreakerLogic
/// @notice Live breaker conditions of markets and debt reserves.
interface IRiskModuleBreakerLogic is IRiskModuleLogic {
    /// @notice Market breaker reasons holding now from live state: `POOL_DEPTH`, `ISSUER` and `CONFIG_DRIFT`.
    function marketConditions(
        uint256 marketId
    ) external view returns (uint32 live);

    /// @notice Debt breaker reasons holding now from live state: `DEFICIT` and `ISSUER`.
    function debtConditions(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32 live);
}
