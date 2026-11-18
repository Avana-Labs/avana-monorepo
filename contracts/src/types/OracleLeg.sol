// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

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
