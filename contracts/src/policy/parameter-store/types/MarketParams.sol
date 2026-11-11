// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Per-market parameters, written by `setInitialMarketParams` in the listing batch and changed by their setters.
/// @custom:spec REQ-CONFIG-015, REQ-CONFIG-041, REQ-PSTORE-004, REQ-PSTORE-005
struct MarketParams {
    // Pool TWAP window, seconds.
    uint32 twapWindow;
    // Consistency-check tolerance, bps of the fair price (for concentrated liquidity, about one bp per tick).
    uint16 consistencyToleranceBps;
    // Slippage allowance, bps.
    uint16 slippageAllowanceBps;
    // Liveness floor of the slippage allowance, bps.
    uint16 slippageAllowanceMinBps;
    // Pool risk factor, bps (> 0, at most 4,000).
    uint16 poolRiskFactor;
    // Minimum value of one pledge, 8-decimal USD (launch 10e8, at most 100_000e8).
    uint256 minPledgeUsd;
    // Optional hard health-factor floor, WAD; 0 = off (default), else within [1e18, 1.25e18] (Q-398).
    uint256 hardHealthFloor;
}
