// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";

/// @title IRiskModuleBreakerLogic
/// @notice Breaker conditions and states of markets and debt reserves.
interface IRiskModuleBreakerLogic is IRiskModuleLogic {
    /// @notice Market breaker reasons holding now from live state.
    function marketConditions(
        uint256 marketId
    ) external view returns (uint32 live);

    /// @notice Debt reasons holding now from live state: `DEFICIT` and `ISSUER`.
    function debtConditions(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32 live);

    /// @notice Tripped reasons of a market breaker (live, recovering and latched) and when its temporary gates reopen.
    function marketBreaker(
        uint256 marketId
    ) external view returns (uint32 reasons, uint64 reopensAt);

    /// @notice Tripped reasons of a debt breaker: live `DEFICIT` and `ISSUER`, recovering and latched.
    function debtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32 reasons, uint64 reopensAt);
}
