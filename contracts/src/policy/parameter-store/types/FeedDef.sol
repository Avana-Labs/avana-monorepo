// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Chainlink feed definition held by the ParameterStore, for every LPOracle leg and debt-reserve price source.
/// @dev `setFeed` pins `maxAnswer` at `min(aggregator maxAnswer, maxAnswerCap)`.
struct FeedDef {
    uint8 decimals;
    int256 minAnswer;
    int256 maxAnswer;
    // Published heartbeat, seconds.
    uint32 feedHeartbeat;
    // Freshness margin added to the heartbeat, seconds.
    uint32 heartbeatMargin;
    // Maximum age of a valid answer, seconds.
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
