// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title OracleInputsLayout
/// @notice Word layout of `IParameterStoreViews.getOracleInputs`, the one read an LPOracle evaluation makes of its
/// configuration (2.9, 2.10 Configuration read on every evaluation).
/// @dev The return value is a `uint256[]` of `HEAD_WORDS + n × stride` words, with `stride = TOKEN_WORDS` or, when
/// second sources are requested, `TOKEN_WORDS + SECOND_WORDS`. Head: `marketId` (0 when the feed is no market's
/// LPOracle), `twapWindow`, `consistencyToleranceBps`, `usdBandLow`, `usdBandHigh`, `cachedWindow`,
/// `disagreementPauseMax`, `graceDuration`, `sequencer.feed`, `sequencer.gracePeriod`. Per token, in the order of the
/// `tokens` argument: `feedAgreementToleranceBps`, `priceRouteVersion`, the replaced slot, the primary's and the
/// alternate's leg counts as the registry returns them, then four legs of `LEG_WORDS` (primary leg 0, primary leg 1,
/// alternate leg 0, alternate leg 1; zero beyond a route's leg count or for a count above 2): aggregator, pinned
/// `decimals`, `minAnswer`, `maxAnswer` (two's complement), `feedHeartbeat`, `heartbeatMargin`, `borrowPriceMaxAge`,
/// `liquidationPriceMaxAge`. Second source in force: `kind`, `source`, `poolRef`, `maxAge`, `twapWindow`,
/// `toleranceBps`, then the source's pinned `decimals`, `minAnswer`, `maxAnswer` (zero unless `OracleNetwork`).
/// Example: a 2-token market is 10 + 2 × 37 = 84 words, or 10 + 2 × 46 = 102 with second sources.
/// @custom:spec REQ-PSTORE-033, REQ-CONFIG-072, REQ-ORACLE-094, REQ-PSTORE-011
library OracleInputsLayout {
    uint256 internal constant HEAD_WORDS = 10;
    uint256 internal constant LEG_WORDS = 8;
    /// @dev Tolerance, version, replaced slot, two leg counts, then four legs.
    uint256 internal constant TOKEN_WORDS = 5 + 4 * LEG_WORDS;
    uint256 internal constant SECOND_WORDS = 9;
}
