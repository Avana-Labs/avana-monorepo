// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpeedView} from "../../../policy/risk-module/types/SpeedView.sol";

/// @notice The app's "available to borrow now" of one market and debt reserve (REQ-LENS-061).
/// @custom:spec REQ-LENS-061, REQ-RISK-097, BOR-024, Q-411
struct BorrowSpeedView {
    // The market window, 8-decimal USD, as the RiskModule reports it.
    SpeedView market;
    // The (funding Hub, asset) window, asset base units, as the RiskModule reports it.
    SpeedView debt;
    // min(⌊market.available × 10^dec / price8⌋, debt.available), asset base units; 0 when either window is unavailable.
    uint256 availableNow;
    // The earlier non-zero moreAt of the two windows, or 0.
    uint64 moreAt;
}
