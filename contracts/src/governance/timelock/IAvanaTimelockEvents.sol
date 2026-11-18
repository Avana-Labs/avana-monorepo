// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaTimelockEvents
/// @notice Events the AvanaTimelock adds to OpenZeppelin `TimelockController`.
interface IAvanaTimelockEvents {
    /// @notice `setNormalDelay` executed.
    event NormalDelayChanged(uint256 previousDelay, uint256 newDelay);

    /// @notice A short-delay list entry was set, at construction or by `setShortDelaySelector`.
    event ShortDelaySelectorSet(address indexed target, bytes4 indexed selector, bool enabled);

    /// @notice Public execution was set, at construction or by `togglePublicExecution`.
    event PublicExecutionToggled(bool enabled);

    /// @notice An expired operation was removed by `cleanupExpiredOperation`.
    event ExpiredOperationCleaned(bytes32 indexed id);
}
