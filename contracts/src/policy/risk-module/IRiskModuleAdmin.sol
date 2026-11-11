// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IRiskModuleAdmin
/// @notice Initialization of the RiskModule proxy. Cap and parameter setters live in the ParameterStore
/// (REQ-RISK-041 to REQ-RISK-045); the RiskModule has no setter.
interface IRiskModuleAdmin {
    /// @notice Initializes the proxy storage.
    /// @dev Runs once, atomically with the proxy deployment. Grants `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` to
    /// `timelock`; the deployer holds no role afterwards.
    /// @param timelock The AvanaTimelock.
    /// @custom:spec REQ-RISK-002, Q-226, Q-228
    function initialize(
        address timelock
    ) external;
}
