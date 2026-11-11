// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveAdapterAdmin
/// @notice Initialization of the AaveAdapter proxy. The Adapter has no setter: every address change is an upgrade
/// (`upgradeToAndCall`, `APPLICATION_ADMIN`, timelock normal delay).
interface IAaveAdapterAdmin {
    /// @notice Initializes the proxy storage.
    /// @dev Runs once, atomically with the proxy deployment; reverts with `ZeroAddress` for a zero `timelock` and with
    /// `AdminRoleOnlyTimelock` unless `timelock == TIMELOCK`. Grants
    /// `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` to `timelock`; the deployer holds no role afterwards.
    /// @param timelock The AvanaTimelock.
    /// @custom:spec REQ-ADAPTER-074, REQ-ADAPTER-003, REQ-ADAPTER-084, Q-226, Q-228, Q-259
    function initialize(
        address timelock
    ) external;
}
