// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One Chainlink leg of an LPOracle price route, as the ParameterStore returns it inside `OracleConfig`.
/// @dev `decimals`, `minAnswer` and `maxAnswer` are pinned at listing from the aggregator; a leg is valid only if
/// `decimals()` equals the pinned value, `minAnswer < answer < maxAnswer`, `0 < updatedAt <= now`,
/// `now - updatedAt <= heartbeat + heartbeatMargin` and the normalised answer is at least 1. Each feed carries its own
/// published heartbeat: Chainlink stablecoin feeds publish 82,800 to 86,400 s, ETH/USD 3,600 s, so one global
/// age limit is wrong for some feed (AMMN-INT-01). Example: USDC/USD on Ethereum, heartbeat 86,400 s, margin 1,800 s:
/// an answer 87,000 s old is fresh (87,000 <= 88,200), one 88,201 s old is stale. Stored in 3 slots: (aggregator,
/// decimals, heartbeat, heartbeatMargin, deviation), (minAnswer, maxAnswer), (borrow and liquidation ages).
/// @custom:spec REQ-ORACLE-002, REQ-ORACLE-049, REQ-CONFIG-022, REQ-CONFIG-023, REQ-CONFIG-072, Q-322
struct OracleLeg {
    // Chainlink aggregator proxy address.
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
