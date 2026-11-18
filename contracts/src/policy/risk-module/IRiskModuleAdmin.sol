// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IRiskModuleAdmin
/// @notice Initialization of the RiskModule proxy; the RiskModule has no setter.
interface IRiskModuleAdmin {
    /// @notice Initializes the proxy storage.
    /// @dev Runs once, with the proxy deployment. Grants `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` to `timelock`.
    function initialize(
        address timelock
    ) external;
}
