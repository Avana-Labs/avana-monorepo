// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Risk tier of a Hub and of the CDP Spokes that draw from it.
/// @dev Ordinal values are fixed.
enum RiskTier {
    None,
    Stable,
    Correlated,
    Volatile
}
