// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Lifecycle status of a market.
/// @dev Ordinal values are fixed.
enum MarketStatus {
    None,
    Registered,
    Active,
    Offboarding,
    Cancelled,
    // Terminal after wind-down: no account of the market has debt.
    Closed
}
