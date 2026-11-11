// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice An account's debt on one approved debt reserve of its CDP Spoke.
/// @dev Amounts are in the debt asset's base units: `drawn` and `premium` from the Spoke's `getUserDebt`, `total` from
/// `getUserTotalDebt(reserveId, proxy)` (drawn rounded up plus premium rounded up). `paused` is the Aave reserve's
/// paused flag. `priceFresh` is true when the reserve's price is Live and within `borrowPriceMaxAge`, the stricter age
/// limit, so borrowing and liquidation can both use it; always true for a fixed-price source (such as GHO). `breakerReasons` is
/// `RiskModule.getDebtBreakerStatus(spoke, reserveId)` (condition and latched).
/// @custom:spec REQ-LENS-009, REQ-LENS-030, REQ-LENS-037, Q-241
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
