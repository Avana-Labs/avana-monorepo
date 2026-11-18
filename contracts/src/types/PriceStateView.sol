// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "./PriceState.sol";
import {TokenPriceView} from "./TokenPriceView.sol";

/// @notice Full price-state report of one market's LPOracle feed, returned by `getPriceState()`.
struct PriceStateView {
    PriceState state;
    // Market reason bitmap.
    uint256 reasons;
    // Served price, 8 decimals, always >= 1.
    int256 answer;
    // Original source timestamp of the served price (oldest input).
    uint64 servedUpdatedAt;
    // block.timestamp - servedUpdatedAt, seconds.
    uint64 servedAge;
    // Per-token report in pool order.
    TokenPriceView[] tokens;
    // |fair price - AMM time-weighted price| in bps of the fair price (type(uint256).max when unavailable).
    uint256 consistencyDeviationBps;
    // Consistency tolerance in bps (the stored value).
    uint16 consistencyToleranceBps;
    // USD level, 8 decimals per 1 USD of value at peg (0 when not evaluated).
    uint256 usdLevel;
    // True when the chain's sequencer reports up and its grace period has passed (true on a chain without one).
    bool sequencerReady;
    // Failure start of the current failure episode (0 when not failed).
    uint64 failureStart;
    // failureStart + cachedWindow (0 when not failed).
    uint64 cachedUntil;
    // First stored observation of the current route disagreement (0 if none).
    uint64 disagreeSince;
    bool disagreementPauseActive;
    // True while a disagreement has outlasted disagreementPauseMax.
    bool disagreementExpired;
    // True while this market's seizure is paused.
    bool liquidationPaused;
    // True when a borrow or withdrawal may rely on this price.
    bool borrowAllowed;
    // Source timestamp of the first fresh update after the last outage that reached Expired (0 if none).
    uint64 recoveredAt;
    // recoveredAt + graceDuration.
    uint64 graceEndsAt;
    // True iff recoveredAt != 0 and recoveredAt <= now < graceEndsAt.
    bool inGrace;
    // Borrow age limit of the served price, seconds (0 fails every age check closed).
    uint32 borrowPriceMaxAge;
    // Liquidation age limit of the served price, seconds (0 fails every age check closed).
    uint32 liquidationPriceMaxAge;
    // Fresh price8 of the current valuation prices, 8 decimals (0 when the market is failed).
    int256 freshAnswer;
    // Last accepted price, 8 decimals.
    int256 acceptedAnswer;
    // Oldest-input source timestamp of the accepted price.
    uint64 acceptedUpdatedAt;
}
