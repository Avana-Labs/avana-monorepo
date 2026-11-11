// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SequencerConfig} from "./SequencerConfig.sol";
import {TokenOracleConfig} from "./TokenOracleConfig.sol";

/// @notice Oracle configuration of one market: `LPOracle.checkConfig` validates it, and every LPOracle evaluation reads
/// its tolerances, consistency-check settings, band and timers from `ParameterStore.getOracleConfig(address(this))`.
/// @dev `tokens[i]` configures the market's token i in pool order; `tokens.length` equals the market's token count.
/// Evaluation reads the routes in force from `MarketRegistry.activePriceRoutes(token)` and each leg from
/// `ParameterStore.getFeed(feed)`. The consistency check compares the fair-composition price with the AMM
/// protocol's own time-weighted price over `twapWindow` when the integration offers one; it gates the price and never
/// feeds it. `twapMinObservations = ceil(twapWindow / blockTime) + 1` sizes the observation buffer to the chain's
/// block time (`SPEC-ORC-022`): a 1,800 s window needs 151 observations at 12 s blocks (Ethereum) and 901 at 2 s
/// blocks (Base), so a short buffer cannot make the TWAP read revert or shorten silently (AMMN-RT-08). `maxQuoteChangeBps` caps the change of the fair price from one block to
/// the next for every AMM protocol, the only spot guard where no TWAP exists: with 100 bps and an accepted price of
/// 2.000000e8 stored in the current block, a new quote of 2.030000e8 (150 bps) is refused and the market is served as
/// Cached at the accepted price for that block; the ParameterStore serves 100 for every market.
/// `usdBandLow` and `usdBandHigh` are 8-decimal USD levels per 1 USD of
/// value at peg (1e8 = 1.00); the lower level is tested on uncapped quotes, the upper on capped valuation prices.
/// `sequencer` is the chain's uptime check (`SequencerConfig`).
/// @custom:spec REQ-ORACLE-005, REQ-ORACLE-007, REQ-ORACLE-046, REQ-ORACLE-083, REQ-ORACLE-094, REQ-ORACLE-099, REQ-ORACLE-100, REQ-ORACLE-103, REQ-CONFIG-072, SPEC-ORC-003, SPEC-ORC-011, SPEC-ORC-020, SPEC-ORC-021, SPEC-ORC-022, Q-322, Q-323, Q-324, Q-326, Q-329
struct OracleConfig {
    // MarketRegistry identifier of the market this feed prices (0 when the feed is no market's LPOracle).
    uint256 marketId;
    // Per-token configuration in pool order.
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
    // Chain sequencer-uptime check.
    SequencerConfig sequencer;
}
