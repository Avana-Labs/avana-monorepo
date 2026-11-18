// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaTimelockViews
/// @notice Views of the AvanaTimelock: delays, the short-delay list, public execution and operation status.
interface IAvanaTimelockViews {
    /// @notice Short delay, seconds (12 hours; 60 seconds on a test network).
    function SHORT_DELAY() external view returns (uint256);

    /// @notice Upper bound of the normal delay, seconds (5 days).
    function MAX_DELAY() external view returns (uint256);

    /// @notice Lower bound of the normal delay, seconds (4 days; 60 seconds on a test network).
    function MIN_NORMAL_DELAY() external view returns (uint256);

    /// @notice How long a ready operation stays executable, seconds (14 days).
    function GRACE_PERIOD() external view returns (uint256);

    /// @notice Current normal delay, seconds.
    function normalDelay() external view returns (uint256);

    /// @notice Whether `(target, selector)` is on the short-delay list.
    function isShortDelaySelector(
        address target,
        bytes4 selector
    ) external view returns (bool);

    /// @notice Whether `(target, selector)` is in the immutable short-eligible set, the only pairs the short-delay
    /// list may ever hold.
    function isShortEligible(
        address target,
        bytes4 selector
    ) external view returns (bool);

    /// @notice Whether `(target, selector)` is in the immutable DAO-only cancel set.
    function isDaoOnlyCancelSelector(
        address target,
        bytes4 selector
    ) external view returns (bool);

    /// @notice Delay these calls need: `SHORT_DELAY` if non-empty and every call is short-listed, else the normal
    /// delay.
    /// @dev Reverts `TimelockInvalidOperationLength` when the arrays differ in length.
    function requiredDelay(
        address[] calldata targets,
        bytes[] calldata payloads
    ) external view returns (uint256 delay);

    /// @notice Whether anyone may execute ready operations.
    function publicExecution() external view returns (bool);

    /// @notice Whether a scheduled, not executed operation reached `readyAt + GRACE_PERIOD`.
    function isOperationExpired(
        bytes32 id
    ) external view returns (bool);

    /// @notice Whether every call of the pending operation is a role change, so only `DAO_CANCELLER_ROLE` may
    /// cancel it.
    function isRoleChangeOperation(
        bytes32 id
    ) external view returns (bool);

    /// @notice Whether every call of the pending operation is in the DAO-only cancel set, so only
    /// `DAO_CANCELLER_ROLE` may cancel it.
    function isRestoringOperation(
        bytes32 id
    ) external view returns (bool);
}
