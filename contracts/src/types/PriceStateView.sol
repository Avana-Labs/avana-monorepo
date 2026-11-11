// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "./PriceState.sol";
import {TokenPriceView} from "./TokenPriceView.sol";

/// @notice Full price-state report of one market's LPOracle feed, returned by `getPriceState()`.
/// @dev Computed by the same code as `latestAnswer()` in the same block, so `answer == latestAnswer()`. `tokens` has
/// one entry per pool token in pool order. `reasons` is the market reason bitmap: bit 0 ANY_TOKEN_NO_ROUTE, 1
/// CONFIG_OR_DECIMALS_UNAVAILABLE, 2 ANY_TOKEN_DISAGREE, 3 USD_BAND, 4 CONSISTENCY_DEVIATION, 5
/// CONSISTENCY_UNAVAILABLE, 6 PRICE_CLAMPED (oracle ratio clamped to the market's range), 7 ANY_TOKEN_ON_ALTERNATE, 8
/// SOURCE_TIMESTAMP_FAILURE, 9 DISAGREEMENT_PAUSE, 10 IN_GRACE, 11 DISAGREEMENT_EXPIRED, 12 ALTERNATE_PAST_BORROW_AGE,
/// 13 ANY_TOKEN_ON_STANDBY, 14 SEQUENCER_DOWN, 15 SEQUENCER_GRACE, 16 SECOND_SOURCE_DISAGREE, 17
/// POOL_REENTRANCY_LOCKED, 18 QUOTE_CHANGE_CAPPED; bits 2 to 6, 11, 12 and 16 are 0 when the market is failed. The
/// per-token detail is in `tokens[i].reasons`. `liquidationPaused = state in {Cached, Expired} or
/// disagreementPauseActive or disagreementExpired or alternatePastBorrowAge or sequencerDown` (SPEC-ORC-016,
/// REQ-ORACLE-090, REQ-ORACLE-099) gates the seizure of this market only (SPEC-ORC-017). `borrowAllowed = state == Live
/// and sequencerReady and every token's second source confirmed and now - servedUpdatedAt <= borrowPriceMaxAge()`
/// (REQ-ORACLE-100). `usdLevel = max{L : L^(x)n <= q_0 (x) q_1 (x) ... (x) q_(n-1)}`, the largest 8-decimal level whose
/// fixed-point power does not exceed the product of the quotes, with `x (x) y = floor(x * y / 1e8)` taken left to right
/// in pool order (SPEC-ORC-011); `usdBandLow <= usdLevel` holds exactly when the lower band test passes. Example:
/// quotes (99,987,000, 100,010,000) give 99,998,499. Bit 18 QUOTE_CHANGE_CAPPED holds the market Cached for one block
/// (REQ-ORACLE-103). AMM-protocol detail (ticks, sqrt prices) is in the integration's extension view, for concentrated
/// liquidity `ILPOracleCL.getClPriceState()`.
/// @custom:spec REQ-ORACLE-042, REQ-ORACLE-016, REQ-ORACLE-021, REQ-ORACLE-022, REQ-ORACLE-034, REQ-ORACLE-084, REQ-ORACLE-090, REQ-ORACLE-099, REQ-ORACLE-100, SPEC-ORC-011, SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-016, SPEC-ORC-017, SPEC-ORC-020, SPEC-ORC-021, Q-128, Q-208, Q-247, Q-323, Q-324
struct PriceStateView {
    // Current price state.
    PriceState state;
    // Market reason bitmap (see @dev).
    uint256 reasons;
    // Served price (SPEC-ORC-017), 8 decimals, always >= 1.
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
    // USD level max{L : L^(x)n <= (x) q_i}, 8 decimals per 1 USD of value at peg (0 when not evaluated).
    uint256 usdLevel;
    // True when the chain's sequencer reports up and its grace period has passed (true on a chain without one).
    bool sequencerReady;
    // Failure start of the current failure episode (0 when not failed).
    uint64 failureStart;
    // failureStart + cachedWindow (0 when not failed).
    uint64 cachedUntil;
    // First stored observation of the current route disagreement (0 if none).
    uint64 disagreeSince;
    // True while the disagreement pause is active.
    bool disagreementPauseActive;
    // True while a disagreement has outlasted disagreementPauseMax.
    bool disagreementExpired;
    // Gates this market's seizure only (see @dev).
    bool liquidationPaused;
    // True when a borrow or withdrawal may rely on this price (see @dev).
    bool borrowAllowed;
    // Source timestamp of the first fresh update after the last outage that reached Expired (0 if none).
    uint64 recoveredAt;
    // recoveredAt + graceDuration.
    uint64 graceEndsAt;
    // True iff recoveredAt != 0 and recoveredAt <= now < graceEndsAt.
    bool inGrace;
    // Borrow age limit of the served price in seconds (SPEC-ORC-015; 0 fails every age check closed).
    uint32 borrowPriceMaxAge;
    // Liquidation age limit of the served price in seconds (SPEC-ORC-015; 0 fails every age check closed).
    uint32 liquidationPriceMaxAge;
    // Fresh price8 of the current valuation prices, 8 decimals (0 when the market is failed).
    int256 freshAnswer;
    // Last accepted price, 8 decimals.
    int256 acceptedAnswer;
    // Oldest-input source timestamp of the accepted price.
    uint64 acceptedUpdatedAt;
}
