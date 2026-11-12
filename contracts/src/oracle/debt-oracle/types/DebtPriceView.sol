// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../../types/PriceState.sol";
import {RouteSlot} from "../../../types/RouteSlot.sol";

/// @notice Full price-state report of one debt asset's DebtOracle, returned by `getPriceState()`.
/// @dev Computed by the same code as `latestAnswer()` in the same block, so `answer == latestAnswer()`. Prices are
/// 8-decimal USD per whole token of the asset; ages and timestamps are seconds; a route value or age that cannot be read
/// is 0 and `type(uint64).max`. `reasons`: bit 0 NO_ROUTE, 2 CONFIG_UNAVAILABLE, 3 DISAGREE, 9 ON_ALTERNATE,
/// 11 SOURCE_TIMESTAMP_FAILURE, 12 DISAGREEMENT_PAUSE, 13 IN_GRACE, 14 DISAGREEMENT_EXPIRED, 15 ALTERNATE_PAST_BORROW_AGE,
/// 16 ON_STANDBY, 17 SEQUENCER_DOWN, 18 SEQUENCER_GRACE, 19 SECOND_SOURCE_DISAGREE; bits 3, 14, 15 and 19 are 0 when
/// failed. `liquidationPaused = state != Live or alternatePastBorrowAge or sequencerDown`: LPVaultSwap repays this
/// asset's reserve only while it is false and the served price is within `liquidationPriceMaxAge`. `borrowAllowed =
/// state == Live and sequencerReady and (on an L2) servedUpdatedAt newer than the sequencer's restart and the second
/// source confirmed and now - servedUpdatedAt <= borrowPriceMaxAge` (REQ-ORACLE-100, SPEC-ORC-021); the RiskModule allows borrowing this asset only while it is true.
/// @custom:spec REQ-ORACLE-093, REQ-ORACLE-092, REQ-ORACLE-090, REQ-ORACLE-099, REQ-ORACLE-100, SPEC-ORC-015, SPEC-ORC-018, SPEC-ORC-020, SPEC-ORC-021, Q-247, Q-248, Q-274, Q-323, Q-324
struct DebtPriceView {
    // Current price state.
    PriceState state;
    // Reason bitmap (see @dev).
    uint256 reasons;
    // Served price (SPEC-ORC-018), always >= 1.
    int256 answer;
    // Source timestamp of the served price: the timestamp of the route whose value is served, else the accepted one.
    uint64 servedUpdatedAt;
    // block.timestamp - servedUpdatedAt.
    uint64 servedAge;
    // Last accepted price.
    uint256 acceptedAnswer;
    // Source timestamp of the accepted price.
    uint64 acceptedUpdatedAt;
    // Route used for the quote: None, Primary or Alternate.
    RouteSlot routeUsed;
    // Uncapped quote q (0 when failed).
    uint256 quote;
    // Primary route value (0 when unreadable).
    uint256 primaryValue;
    // Age of the primary route (type(uint64).max when unreadable).
    uint64 primaryAge;
    // Alternate route value (0 when unreadable).
    uint256 alternateValue;
    // Age of the alternate route (type(uint64).max when unreadable).
    uint64 alternateAge;
    // Informational agreement deviation floor(|p - b| * 1e4 / min(p, b)) in bps.
    uint256 deviationBps;
    // Feed-agreement tolerance T in bps (the stored value).
    uint16 feedAgreementToleranceBps;
    // Slot the asset's standby route replaces in MarketRegistry.activePriceRoutes (None when not switched).
    RouteSlot replaced;
    // MarketRegistry.priceRouteVersion(asset) read in this evaluation.
    uint64 routeVersion;
    // Chainlink aggregator proxies of the served route, in leg order (address(0) for an unused slot, and both when the
    // accepted price is served).
    address[2] legFeeds;
    // Original Chainlink `updatedAt` of each leg.
    uint64[2] legUpdatedAt;
    // borrowPriceMaxAge of each leg.
    uint32[2] legBorrowPriceMaxAge;
    // liquidationPriceMaxAge of each leg (min with borrowPriceMaxAge on an alternate route).
    uint32[2] legLiquidationPriceMaxAge;
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
    // True when the state is not Live, a serving alternate's leg is past its borrowPriceMaxAge, or the sequencer is down.
    bool liquidationPaused;
    // Source timestamp of the first fresh update after the last outage that reached Expired (0 if none).
    uint64 recoveredAt;
    // recoveredAt + graceDuration.
    uint64 graceEndsAt;
    // True iff recoveredAt != 0 and recoveredAt <= now < graceEndsAt.
    bool inGrace;
    // Borrow age limit of the served price (SPEC-ORC-015; 0 when the accepted price is served).
    uint32 borrowPriceMaxAge;
    // Liquidation age limit of the served price (SPEC-ORC-015; 0 when the accepted price is served).
    uint32 liquidationPriceMaxAge;
    // ParameterStore.debtStressRiseBps(asset) read into [.., 5,000] bps (the last writing call's value on a failed read).
    uint16 debtStressRiseBps;
    // Price served once Expired: ceil(acceptedAnswer * (1e4 + debtStressRiseBps) / 1e4).
    uint256 stressAnswer;
    // Live, sequencer ready, second source confirmed and the served price within borrowPriceMaxAge (REQ-ORACLE-100).
    bool borrowAllowed;
}
