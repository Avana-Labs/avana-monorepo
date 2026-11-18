// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice An account's debt on one approved debt reserve of its CDP Spoke.
/// @dev Amounts in debt-asset base units. `priceFresh` uses the stricter borrow age limit.
struct DebtPosition {
    uint256 reserveId;
    address asset;
    uint256 drawn;
    uint256 premium;
    uint256 total;
    bool paused;
    bool priceFresh;
    uint32 breakerReasons;
}
