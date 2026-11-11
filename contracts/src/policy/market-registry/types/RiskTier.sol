// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Risk tier of a Hub and of the CDP Spokes that draw from it.
/// @dev `Stable`: pools of USD-pegged tokens (launch tier). `Correlated`: pools of tokens that track each other (for
/// example WETH and a liquid-staking token). `Volatile`: pools of uncorrelated tokens. Ordinal values are fixed.
/// @custom:spec REQ-CONFIG-016, Q-378
enum RiskTier {
    None,
    Stable,
    Correlated,
    Volatile
}
