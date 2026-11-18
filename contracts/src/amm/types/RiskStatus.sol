// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Time-weighted pool depth of one market, returned by `IAmmIntegration.riskStatus`.
struct RiskStatus {
    // Time-weighted depth over the window, the market's units.
    uint256 depthUnits;
    // False when the AMM protocol keeps no history covering the window.
    bool depthAvailable;
}
