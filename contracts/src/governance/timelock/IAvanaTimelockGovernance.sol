// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaTimelockGovernance
/// @notice Configuration of the AvanaTimelock itself, plus the public clean-up of expired operations.
interface IAvanaTimelockGovernance {
    /// @notice Sets the delay of every operation that is not entirely on the short-delay list.
    /// @dev Only the timelock. Reverts `DelayOutOfBounds` outside `[MIN_NORMAL_DELAY, MAX_DELAY]`.
    function setNormalDelay(
        uint256 newDelay
    ) external;

    /// @notice Adds or removes one `(target, selector)` pair of the short-delay list.
    /// @dev Only the timelock. Reverts `InvalidShortDelaySelector` when enabling a pair outside the short-eligible set.
    function setShortDelaySelector(
        address target,
        bytes4 selector,
        bool enabled
    ) external;

    /// @notice Turns public execution on or off.
    /// @dev Only the timelock.
    function togglePublicExecution(
        bool enabled
    ) external;

    /// @notice Removes an expired operation so the same calls can be scheduled again.
    /// @dev Callable by anyone; reverts `OperationNotExpired` unless the operation is expired.
    function cleanupExpiredOperation(
        bytes32 id
    ) external;
}
