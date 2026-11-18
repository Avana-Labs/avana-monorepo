// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpeedView} from "../../../policy/risk-module/types/SpeedView.sol";

/// @notice The amount available to borrow now for one market and debt reserve.
struct BorrowSpeedView {
    // The market window, 8-decimal USD, as the RiskModule reports it.
    SpeedView market;
    // The (funding Hub, asset) window, asset base units, as the RiskModule reports it.
    SpeedView debt;
    // The smaller of both windows, asset base units; 0 when either window is unavailable.
    uint256 availableNow;
    // The earlier non-zero moreAt of the two windows, or 0.
    uint64 moreAt;
}
