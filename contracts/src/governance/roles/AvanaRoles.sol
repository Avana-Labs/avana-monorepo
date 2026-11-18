// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title AvanaRoles
/// @notice Role identifiers Avana adds to OpenZeppelin `AccessControl` and `TimelockController`.
/// @dev Each chain has its own AvanaTimelock and role holders; no role reaches across chains.
library AvanaRoles {
    /// @notice Upgrades, setters, listings and keepers on every upgradeable Avana contract; held only by the timelock.
    bytes32 internal constant APPLICATION_ADMIN = keccak256("APPLICATION_ADMIN");

    /// @notice Immediate pause, unpause, unfreeze, breaker resets and standby switches.
    bytes32 internal constant APPLICATION_PAUSE_GUARDIAN = keccak256("APPLICATION_PAUSE_GUARDIAN");

    /// @notice Immediate freezes and breaker trips on the MarketRegistry.
    bytes32 internal constant APPLICATION_FREEZE_GUARDIAN = keccak256("APPLICATION_FREEZE_GUARDIAN");

    /// @notice Immediate ParameterStore tighten setters and `setAvanaFeeShareBps`.
    bytes32 internal constant APPLICATION_RISK_STEWARD = keccak256("APPLICATION_RISK_STEWARD");

    /// @notice Required with `CANCELLER_ROLE` to cancel a role-change or restoring timelock operation.
    bytes32 internal constant DAO_CANCELLER_ROLE = keccak256("DAO_CANCELLER_ROLE");
}
