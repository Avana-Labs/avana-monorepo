// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice A token's Chainlink price-route slot that its pre-approved standby route can replace.
/// @dev Ordinal values are fixed.
enum RouteSlot {
    None,
    Primary,
    Alternate
}
