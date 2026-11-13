// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Borrow-speed limit of one (funding Hub, debt asset): at most `clamp(rateBps × base / 10^4, min, max)` base
/// units of new draws per window of `window` seconds, the base being the asset every Avana CDP Spoke owes the Hub.
/// @dev One storage slot. All zero until the first `loosenDebtSpeedLimit`, which the RiskModule reads as a closed window.
/// Written by `tightenDebtSpeedLimit` and `loosenDebtSpeedLimit` (REQ-PSTORE-036).
/// @custom:spec REQ-PSTORE-035, REQ-RISK-092, SPEC-CAP-012, Q-411
struct SpeedLimit {
    // Share of the base allowed per window, bps (at most 10,000).
    uint16 rateBps;
    // Window length tau, seconds (3,600 to 604,800 once written).
    uint32 window;
    // Smallest limit, asset base units.
    uint96 min;
    // Largest limit, asset base units (at least `min`).
    uint96 max;
}
