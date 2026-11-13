// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Borrow-speed and pledge-speed limits of one market, sharing one window length.
/// @dev Two storage slots. New debt per window at most `clamp(borrowRateBps × D_m / 10^4, borrowMinUsd, borrowMaxUsd)`
/// and booked collateral per window at most `clamp(pledgeRateBps × V / 10^4, pledgeMinUsd, pledgeMaxUsd)`, 8-decimal
/// USD. All zero until the listing batch's `loosenMarketSpeedLimits`, which the RiskModule reads as closed windows.
/// @custom:spec REQ-PSTORE-035, REQ-RISK-092, REQ-RISK-093, SPEC-CAP-012, Q-411
struct MarketSpeedLimits {
    // Window length tau, seconds (3,600 to 604,800 once written).
    uint32 window;
    // Borrow rate alpha, bps of the base (at most 10,000).
    uint16 borrowRateBps;
    // Pledge rate beta, bps of the base (at most 10,000).
    uint16 pledgeRateBps;
    // Smallest borrow limit L_min, 8-decimal USD.
    uint96 borrowMinUsd;
    // Largest borrow limit L_max, 8-decimal USD (at least `borrowMinUsd`).
    uint96 borrowMaxUsd;
    // Smallest pledge limit P_min, 8-decimal USD.
    uint96 pledgeMinUsd;
    // Largest pledge limit P_max, 8-decimal USD (at least `pledgeMinUsd`).
    uint96 pledgeMaxUsd;
}
