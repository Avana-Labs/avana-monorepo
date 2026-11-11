// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice How an AMM protocol pays trading fees to a position.
/// @dev `Separate`: fees accrue apart from principal and are collected (Uniswap v3, Slipstream, Uniswap v4); the
/// fair price excludes them, since a wash trader can raise uncollected fees in one transaction. `RolledIn`: fees
/// compound into the pool's reserves and raise the value of each unit (Uniswap v2, Curve, Balancer); there is nothing
/// to collect and `collectFees` reverts with `FeesRolledIn`. Ordinal values are fixed.
/// @custom:spec REQ-AMM-CORE-011, Q-371
enum FeeMode {
    Separate,
    RolledIn
}
