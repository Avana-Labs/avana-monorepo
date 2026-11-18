// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveAdapterAdmin
/// @notice Initialization of the AaveAdapter proxy. The Adapter has no setters: every address change is an upgrade.
interface IAaveAdapterAdmin {
    /// @notice Initializes the proxy storage.
    /// @dev Runs once; `timelock` must equal `TIMELOCK`. Grants the admin roles to `timelock` only.
    function initialize(
        address timelock
    ) external;
}
