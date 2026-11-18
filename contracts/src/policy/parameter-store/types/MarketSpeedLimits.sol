// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Borrow-speed and pledge-speed limits of one market, sharing one window length.
struct MarketSpeedLimits {
    // Window length, seconds.
    uint32 window;
    // Borrow rate, bps of the base.
    uint16 borrowRateBps;
    // Pledge rate, bps of the base.
    uint16 pledgeRateBps;
    // Smallest borrow limit, 8-decimal USD.
    uint96 borrowMinUsd;
    // Largest borrow limit, 8-decimal USD.
    uint96 borrowMaxUsd;
    // Smallest pledge limit, 8-decimal USD.
    uint96 pledgeMinUsd;
    // Largest pledge limit, 8-decimal USD.
    uint96 pledgeMaxUsd;
}
