// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Chainlink feed definition held by the ParameterStore, for every LPOracle leg and every debt-reserve
/// price source.
/// @dev `decimals` is read on-chain and pinned; `minAnswer` is read on-chain from the feed's aggregator by `setFeed`,
/// and the pinned `maxAnswer` is `min(aggregator().maxAnswer(), maxAnswerCap)`, where `maxAnswerCap` is Avana's own
/// bound recorded at listing (its largest value when the aggregator's bound already keeps every route value within
/// `MAX_ROUTE_ANSWER`; for an aggregator deployed with a sentinel `maxAnswer`, the bound that does, REQ-ORACLE-049).
/// Example: an 8-decimal stable feed with aggregator `maxAnswer = 2^176 - 1` and `maxAnswerCap = 10^12` is pinned at
/// `10^12`. `feedHeartbeat` is the feed's own configured heartbeat (82,800 to 86,400 s for Chainlink
/// stablecoin feeds, `0 < feedHeartbeat <= 86,400`) and `heartbeatMargin` its freshness margin (launch 1,800 s, at most
/// `MAX_HEARTBEAT_MARGIN` = 3,600 s). `setFeed` writes `feedMaxAge = liquidationPriceMaxAge = feedHeartbeat +
/// heartbeatMargin` and `borrowPriceMaxAge <= feedMaxAge`, equal for a new feed; a later `setFeed` keeps a
/// lower `borrowPriceMaxAge` a tightening wrote (`SPEC-ORC-019`). Example: USDT/USD with
/// a heartbeat of 86,400 s and a margin of 1,800 s has `feedMaxAge = 88,200` s.
/// @custom:spec REQ-CONFIG-022, REQ-CONFIG-023, REQ-ORACLE-002, REQ-ORACLE-049, REQ-ORACLE-054, REQ-HUB-104, SPEC-ORC-019, Q-322
struct FeedDef {
    // Pinned decimals.
    uint8 decimals;
    // Aggregator minAnswer (raw units).
    int256 minAnswer;
    // Pinned maxAnswer, min(aggregator maxAnswer, maxAnswerCap) (raw units).
    int256 maxAnswer;
    // Published heartbeat, seconds.
    uint32 feedHeartbeat;
    // Freshness margin added to the heartbeat, seconds.
    uint32 heartbeatMargin;
    // Maximum age of a valid answer in LPOracle state evaluation, seconds.
    uint32 feedMaxAge;
    // Published deviation threshold, bps.
    uint16 feedDeviationThresholdBps;
    // Heartbeat drift allowance, bps.
    uint16 heartbeatDriftBps;
    // Borrow age limit, seconds.
    uint32 borrowPriceMaxAge;
    // Liquidation age limit, seconds.
    uint32 liquidationPriceMaxAge;
    // Avana's cap on the pinned maxAnswer (raw units), recorded at listing; type(int256).max for none.
    int256 maxAnswerCap;
}
