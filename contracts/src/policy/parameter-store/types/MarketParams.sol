// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Per-market parameters, first written by `setInitialMarketParams` in the listing batch.
struct MarketParams {
    // Pool TWAP window, seconds.
    uint32 twapWindow;
    // Consistency-check tolerance, bps of the fair price.
    uint16 consistencyToleranceBps;
    // Slippage allowance, bps.
    uint16 slippageAllowanceBps;
    // Liveness floor of the slippage allowance, bps.
    uint16 slippageAllowanceMinBps;
    // Pool risk factor, bps.
    uint16 poolRiskFactor;
    // Minimum value of one pledge, 8-decimal USD.
    uint256 minPledgeUsd;
    // Optional hard health-factor floor, WAD; 0 = off.
    uint256 hardHealthFloor;
}
