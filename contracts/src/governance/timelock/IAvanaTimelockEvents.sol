// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaTimelockEvents
/// @notice Events the AvanaTimelock adds to OpenZeppelin `TimelockController` (`CallScheduled`, `CallSalt`,
/// `CallExecuted`, `Cancelled`, `MinDelayChange`) and `AccessControl` (`RoleGranted`, `RoleRevoked`,
/// `RoleAdminChanged`).
interface IAvanaTimelockEvents {
    /// @notice `setNormalDelay` executed.
    /// @param previousDelay Old normal delay, seconds.
    /// @param newDelay New normal delay, seconds.
    /// @custom:spec SPEC-GOV-003, REQ-ACCESS-029
    event NormalDelayChanged(uint256 previousDelay, uint256 newDelay);

    /// @notice A short-delay list entry was set, at construction or by `setShortDelaySelector`.
    /// @param target Contract the selector belongs to.
    /// @param selector Function selector.
    /// @param enabled Whether the pair is now on the list.
    /// @custom:spec REQ-ACCESS-141
    event ShortDelaySelectorSet(address indexed target, bytes4 indexed selector, bool enabled);

    /// @notice Public execution was set, at construction or by `togglePublicExecution`.
    /// @param enabled Whether anyone may now execute ready operations.
    /// @custom:spec REQ-ACCESS-144
    event PublicExecutionToggled(bool enabled);

    /// @notice An expired operation was removed by `cleanupExpiredOperation`.
    /// @param id Operation identifier.
    /// @custom:spec SPEC-GOV-013, REQ-ACCESS-108
    event ExpiredOperationCleaned(bytes32 indexed id);
}
