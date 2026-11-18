// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SequencerConfig} from "./SequencerConfig.sol";
import {TokenOracleConfig} from "./TokenOracleConfig.sol";

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
