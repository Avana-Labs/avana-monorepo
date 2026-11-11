// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaTimelockGovernance
/// @notice Configuration of the AvanaTimelock itself, plus the public clean-up of expired operations. The three
/// setters are callable only by the timelock (a self-call executed as an operation whose target is the timelock), so
/// each change waits the normal delay and is cancellable by any canceller. `updateDelay` from OpenZeppelin always
/// reverts `UpdateDelayDisabled`.
interface IAvanaTimelockGovernance {
    /// @notice Sets the delay of every operation that is not entirely on the short-delay list.
    /// @dev Only the timelock. Reverts `DelayOutOfBounds` unless `MIN_NORMAL_DELAY <= newDelay <= MAX_DELAY`
    /// (345,600 to 432,000). Applies to operations scheduled after it executes; emits `NormalDelayChanged`.
    /// @param newDelay New normal delay, seconds (launch 432,000).
    /// @custom:spec SPEC-GOV-003, SPEC-GOV-015, REQ-ACCESS-029, REQ-ACCESS-125, REQ-ACCESS-154
    function setNormalDelay(
        uint256 newDelay
    ) external;

    /// @notice Adds or removes one `(target, selector)` pair of the short-delay list.
    /// @dev Only the timelock. Reverts `InvalidShortDelaySelector` when enabling a pair that is not in the immutable
    /// `SHORT_ELIGIBLE` set fixed by the constructor (which never holds the timelock as target or a role, upgrade
    /// or initializer selector); disabling is always allowed. Emits `ShortDelaySelectorSet`.
    /// @param target Contract the selector belongs to.
    /// @param selector Function selector.
    /// @param enabled True to add, false to remove.
    /// @custom:spec REQ-ACCESS-029, REQ-ACCESS-141, REQ-ACCESS-142, REQ-ACCESS-152, REQ-ACCESS-155
    function setShortDelaySelector(
        address target,
        bytes4 selector,
        bool enabled
    ) external;

    /// @notice Turns public execution on or off.
    /// @dev Only the timelock. While on, anyone executes ready operations; while off, only `EXECUTOR_ROLE`. Grants or
    /// revokes `EXECUTOR_ROLE` for `address(0)` (OpenZeppelin's open role) and emits `PublicExecutionToggled`; a call
    /// that leaves the value unchanged changes nothing and emits nothing.
    /// @param enabled New value (launch `true`).
    /// @custom:spec REQ-ACCESS-029, REQ-ACCESS-144
    function togglePublicExecution(
        bool enabled
    ) external;

    /// @notice Removes an expired operation so the same calls can be scheduled again.
    /// @dev Anyone. Reverts `OperationNotExpired` unless `isOperationExpired(id)`; afterwards `getTimestamp(id)` is 0
    /// (state `Unset`) until `id` is scheduled again, the role-change and restoring marks are cleared, and
    /// `ExpiredOperationCleaned` is emitted.
    /// @param id Operation identifier.
    /// @custom:spec SPEC-GOV-013, REQ-ACCESS-126
    function cleanupExpiredOperation(
        bytes32 id
    ) external;
}
