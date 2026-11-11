// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Kind of position shape a market accepts.
/// @dev `TickRange`: a concentrated-liquidity position whose `[tickLower, tickUpper]` must equal the market's range
/// exactly (Uniswap v3, Slipstream, Uniswap v4; AMMN-RT-01). `FullPool`: a pro-rata share of the whole pool, held as
/// fungible LP tokens (Uniswap v2, Curve, Balancer). Ordinal values are fixed.
/// @custom:spec REQ-AMM-CORE-003, Q-370
enum ShapeKind {
    None,
    TickRange,
    FullPool
}
