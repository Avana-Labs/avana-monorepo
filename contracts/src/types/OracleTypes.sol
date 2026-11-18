// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceInput} from "../lens/lens/types/LensTypes.sol";

/// @notice Oracle configuration of one market, read by the LPOracle from the ParameterStore.
/// @dev `tokens[i]` configures the market's token i in pool order.
struct OracleConfig {
    // MarketRegistry identifier of the market this feed prices (0 when the feed is no market's LPOracle).
    uint256 marketId;
    TokenOracleConfig[] tokens;
    // Consistency-check window W, seconds (0 when the AMM protocol has no time-weighted price).
    uint32 twapWindow;
    // Minimum observation-buffer length the pool must hold for W at this chain's block time.
    uint16 twapMinObservations;
    // Consistency-check tolerance, bps of the fair price.
    uint16 consistencyToleranceBps;
    // Largest accepted change of the fair price between two blocks, bps of the previous accepted price.
    uint16 maxQuoteChangeBps;
    // Lower USD band level, 8 decimals.
    uint256 usdBandLow;
    // Upper USD band level, 8 decimals.
    uint256 usdBandHigh;
    // Length of the Cached state measured from the first failed read, seconds.
    uint32 cachedWindow;
    // Maximum liquidation pause while routes disagree, seconds.
    uint32 disagreementPauseMax;
    // Recovery grace length, seconds.
    uint32 graceDuration;
    SequencerConfig sequencer;
}

/// @notice One Chainlink leg of an LPOracle price route, as the ParameterStore returns it inside `OracleConfig`.
/// @dev An answer is fresh while `now - updatedAt <= heartbeat + heartbeatMargin`.
struct OracleLeg {
    address aggregator;
    // Pinned decimals of the aggregator.
    uint8 decimals;
    // Published heartbeat of this feed, seconds.
    uint32 heartbeat;
    // Freshness margin added to the heartbeat, seconds.
    uint16 heartbeatMargin;
    // Published deviation threshold of this feed, bps.
    uint16 feedDeviationThresholdBps;
    // Pinned minAnswer of the underlying aggregator (raw units).
    int128 minAnswer;
    // Pinned maxAnswer of the underlying aggregator (raw units).
    int128 maxAnswer;
    // Borrow age limit of this feed, seconds (at most heartbeat + heartbeatMargin).
    uint32 borrowPriceMaxAge;
    // Liquidation age limit of this feed, seconds.
    uint32 liquidationPriceMaxAge;
}

/// @notice One Chainlink price route of a token: a direct TOKEN/USD leg, or two legs multiplied (TOKEN/X then X/USD).
/// @dev Only `legs[0 .. legCount - 1]` are used; the route timestamp is the oldest leg `updatedAt`.
struct OracleRoute {
    // Number of legs in use, 1 or 2.
    uint8 legCount;
    // Legs in multiplication order.
    OracleLeg[2] legs;
}

/// @notice A token's Chainlink price-route slot that its pre-approved standby route can replace.
/// @dev Ordinal values are fixed.
enum RouteSlot {
    None,
    Primary,
    Alternate
}

/// @notice Independent second price source of one token, required to agree before a borrow or a withdrawal.
/// @dev Passes when `|q - s| * 1e4 <= toleranceBps * min(q, s)`; liquidation never reads it.
struct SecondSource {
    SecondSourceKind kind;
    // Aggregator (OracleNetwork) or AMM integration (PoolTwap).
    address source;
    // Pool address or identifier for PoolTwap (bytes32(uint160(pool)) for an address-keyed pool).
    bytes32 poolRef;
    // Maximum accepted age of an OracleNetwork answer, seconds.
    uint32 maxAge;
    // TWAP window of a PoolTwap, seconds.
    uint32 twapWindow;
    // Agreement tolerance with the served quote, bps.
    uint16 toleranceBps;
}

/// @notice Kind of a token's independent second price source.
/// @dev Ordinal values are fixed.
enum SecondSourceKind {
    None,
    OracleNetwork,
    PoolTwap
}

/// @notice L2 sequencer-uptime check of a chain.
/// @dev `feed == address(0)` on a chain without a sequencer.
struct SequencerConfig {
    // Chainlink sequencer-uptime feed, or address(0).
    address feed;
    // Grace period after a restart, seconds.
    uint32 gracePeriod;
}

/// @notice Oracle configuration of one pool token inside a market's `OracleConfig`.
struct TokenOracleConfig {
    // Pool token (must equal Market.tokens[i]).
    address token;
    // Primary and alternate Chainlink routes.
    OracleRoute[2] routes;
    // Primary-versus-alternate agreement tolerance, bps.
    uint16 feedAgreementToleranceBps;
    // Independent second source for borrow and withdraw.
    SecondSource secondSource;
}

/// @notice Price state of one market's LPOracle feed or one debt asset's DebtOracle, ordered by severity.
enum PriceState {
    Live,
    Drifting,
    Cached,
    Expired
}

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

/// @notice Price state report of one market.
struct PriceView {
    uint256 blockNumber;
    uint256 timestamp;
    address vaultToken;
    address feed;
    PriceState state;
    PriceState liquidationState;
    uint256 reasons;
    uint256 price;
    uint256 acceptedPrice;
    uint256 acceptedAt;
    PriceInput[] inputs;
    uint256[] tokenDeviationBps;
    uint256 disagreeSince;
    bool disagreementPauseActive;
    bool disagreementExpired;
    uint256 recoveredAt;
    uint256 graceEndsAt;
    uint256 graceHealthFactor;
    bool borrowAllowed;
}

/// @notice Per-token part of an LPOracle price-state report.
/// @dev Prices are 8-decimal USD per whole token; ages and timestamps are seconds.
struct TokenPriceView {
    address token;
    uint32 reasons;
    // Route used for the quote: 0 None, 1 Primary, 2 Alternate.
    uint8 routeUsed;
    // Uncapped quote q_i (8 decimals).
    uint256 quote;
    // Valuation price v_i = q_i after the stable ceiling (8 decimals).
    uint256 valuationPrice;
    // Quote timestamp t_i, the oldest leg timestamp of the route used (seconds).
    uint64 updatedAt;
    // Primary route value (8 decimals, 0 when unreadable).
    uint256 primaryValue;
    // Age of the primary route in seconds (type(uint64).max when unreadable).
    uint64 primaryAge;
    // Alternate route value (8 decimals, 0 when unreadable).
    uint256 alternateValue;
    // Age of the alternate route in seconds (type(uint64).max when unreadable).
    uint64 alternateAge;
    // Informational agreement deviation floor(|p - b| * 1e4 / min(p, b)) in bps.
    uint256 deviationBps;
    // Feed-agreement tolerance T_i in bps (the stored value).
    uint16 feedAgreementToleranceBps;
    // Second-source value (8 decimals, 0 when unreadable or not configured).
    uint256 secondSourceValue;
    // floor(|q - s| * 1e4 / min(q, s)) in bps (type(uint256).max when unreadable).
    uint256 secondSourceDeviationBps;
    // Chainlink aggregator proxies of the selected route, in leg order.
    address[2] legFeeds;
    // Original Chainlink `updatedAt` of each leg (seconds).
    uint64[2] legUpdatedAt;
    // borrowPriceMaxAge of each leg (seconds).
    uint32[2] legBorrowPriceMaxAge;
    // liquidationPriceMaxAge of each leg (seconds).
    uint32[2] legLiquidationPriceMaxAge;
    // Slot the token's standby route replaces (None when both recorded routes are in force).
    RouteSlot replaced;
    // MarketRegistry.priceRouteVersion(token) read in this evaluation.
    uint64 routeVersion;
}
