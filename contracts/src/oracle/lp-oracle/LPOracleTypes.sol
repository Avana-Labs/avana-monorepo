// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../types/PriceState.sol";
import {SecondSource} from "../../types/SecondSource.sol";

/// @title LPOracleCodes
/// @notice Leg and route classes, route slots, market and token reason bits and `checkConfig` bits of the LPOracle
/// (2.10 Reason bits, `REQ-ORACLE-003`, `REQ-ORACLE-004`, `REQ-ORACLE-046`).
/// @custom:spec REQ-ORACLE-003, REQ-ORACLE-004, REQ-ORACLE-042, REQ-ORACLE-046
library LPOracleCodes {
    // Leg and route classes (`REQ-ORACLE-003`, `REQ-ORACLE-004`).
    uint8 internal constant VALID = 0;
    uint8 internal constant STALE = 1;
    uint8 internal constant INVALID = 2;
    uint8 internal constant ERROR = 3;

    // Route used for a token's quote: 0 None, 1 Primary, 2 Alternate (`RouteChanged`, `TokenPriceView.routeUsed`).
    uint8 internal constant ROUTE_NONE = 0;
    uint8 internal constant ROUTE_PRIMARY = 1;
    uint8 internal constant ROUTE_ALTERNATE = 2;

    // Market reason bits (2.10 Reason bits).
    uint256 internal constant ANY_TOKEN_NO_ROUTE = 1 << 0;
    uint256 internal constant CONFIG_OR_DECIMALS_UNAVAILABLE = 1 << 1;
    uint256 internal constant ANY_TOKEN_DISAGREE = 1 << 2;
    uint256 internal constant USD_BAND = 1 << 3;
    uint256 internal constant CONSISTENCY_DEVIATION = 1 << 4;
    uint256 internal constant CONSISTENCY_UNAVAILABLE = 1 << 5;
    uint256 internal constant PRICE_CLAMPED = 1 << 6;
    uint256 internal constant ANY_TOKEN_ON_ALTERNATE = 1 << 7;
    uint256 internal constant SOURCE_TIMESTAMP_FAILURE = 1 << 8;
    uint256 internal constant DISAGREEMENT_PAUSE = 1 << 9;
    uint256 internal constant IN_GRACE = 1 << 10;
    uint256 internal constant DISAGREEMENT_EXPIRED = 1 << 11;
    uint256 internal constant ALTERNATE_PAST_BORROW_AGE = 1 << 12;
    uint256 internal constant ANY_TOKEN_ON_STANDBY = 1 << 13;
    uint256 internal constant SEQUENCER_DOWN = 1 << 14;
    uint256 internal constant SEQUENCER_GRACE = 1 << 15;
    uint256 internal constant SECOND_SOURCE_DISAGREE = 1 << 16;
    uint256 internal constant POOL_REENTRANCY_LOCKED = 1 << 17;
    uint256 internal constant QUOTE_CHANGE_CAPPED = 1 << 18;

    /// @dev Bits 2 to 6 make a market that is not failed Drifting (`REQ-ORACLE-018`).
    uint256 internal constant DRIFTING_BITS = (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6);

    /// @dev Bits 2 to 6, 11, 12 and 16 are not evaluated, and are 0, when the market is failed.
    uint256 internal constant NOT_EVALUATED_WHEN_FAILED = DRIFTING_BITS | (1 << 11) | (1 << 12) | (1 << 16);

    // Token reason bits.
    uint32 internal constant TOKEN_NO_ROUTE = 1 << 0;
    uint32 internal constant TOKEN_DISAGREE = 1 << 1;
    uint32 internal constant TOKEN_ON_ALTERNATE = 1 << 2;
    uint32 internal constant TOKEN_ON_STANDBY = 1 << 3;
    uint32 internal constant TOKEN_SECOND_SOURCE_DISAGREE = 1 << 4;
    uint32 internal constant TOKEN_SECOND_SOURCE_UNAVAILABLE = 1 << 5;

    // `checkConfig` bits (`REQ-ORACLE-046`); bits 16 and above belong to the pricing module's `listingChecks`.
    uint256 internal constant CHECK_TOKENS = 1 << 0;
    uint256 internal constant CHECK_TOKEN_DECIMALS = 1 << 1;
    uint256 internal constant CHECK_LEG_DECIMALS = 1 << 2;
    uint256 internal constant CHECK_LEG_BOUNDS = 1 << 3;
    uint256 internal constant CHECK_ROUTE_RANGE = 1 << 4;
    uint256 internal constant CHECK_HEARTBEAT = 1 << 5;
    uint256 internal constant CHECK_SHOCK = 1 << 6;
    uint256 internal constant CHECK_VAULT_DECIMALS = 1 << 7;
    uint256 internal constant CHECK_SHARED_FEED = 1 << 8;
    uint256 internal constant CHECK_TOLERANCE = 1 << 9;
    uint256 internal constant CHECK_SECOND_SOURCE = 1 << 10;
    uint256 internal constant CHECK_QUOTES = 1 << 11;
    uint256 internal constant CHECK_QUOTE_CAP = 1 << 12;
    uint256 internal constant CHECK_SEQUENCER = 1 << 13;
    uint256 internal constant CHECK_USD_BAND = 1 << 14;
    uint256 internal constant CHECK_MARKET = 1 << 15;
    uint256 internal constant MODULE_CHECKS_SHIFT = 16;
}

/// @notice One leg of a route in force: its pinned settings and what this evaluation read from the aggregator.
/// @dev `status` is a class of `LPOracleCodes`; `decoded` is true when `latestRoundData()` returned decodable data
/// (valid, `Stale` or `Invalid`), which `poke()` records in `seen` (`REQ-ORACLE-031`).
/// @custom:spec REQ-ORACLE-001, REQ-ORACLE-002, REQ-ORACLE-003, REQ-ORACLE-031, SPEC-ORC-019
struct LegEval {
    // Chainlink aggregator proxy.
    address feed;
    // Pinned decimals.
    uint8 pinnedDecimals;
    // Pinned minAnswer and maxAnswer (raw units).
    int256 minAnswer;
    int256 maxAnswer;
    // feedMaxAge = feedHeartbeat + heartbeatMargin, seconds.
    uint64 maxAge;
    // Borrow and liquidation age limits of the feed, seconds.
    uint32 borrowAge;
    uint32 liquidationAge;
    // Class of the leg in this evaluation.
    uint8 status;
    // latestRoundData() returned decodable data.
    bool decoded;
    // Round read.
    uint80 roundId;
    int256 answer;
    uint64 updatedAt;
    // decimals() read (0 when unreadable).
    uint8 readDecimals;
}

/// @notice One route in force (one or two legs) and its value, timestamp and class in this evaluation.
/// @custom:spec SPEC-ORC-002, SPEC-ORC-013, REQ-ORACLE-004
struct RouteEval {
    // Legs in use, 1 or 2.
    uint8 legCount;
    // Class of the route.
    uint8 status;
    // Route value r, 8 decimals (0 when not computable).
    uint256 value;
    // Route timestamp: the oldest leg.
    uint64 updatedAt;
    // staleFrom_r of a Stale route (`SPEC-ORC-013`).
    uint64 staleFrom;
    // Legs in multiplication order.
    LegEval[2] legs;
}

/// @notice One market token in this evaluation: its two routes in force, quote, valuation and second source.
/// @custom:spec REQ-ORACLE-005, REQ-ORACLE-008, REQ-ORACLE-009, REQ-ORACLE-094, SPEC-ORC-017, SPEC-ORC-020
struct TokenEval {
    // Primary (0) and alternate (1) routes in force.
    RouteEval[2] routes;
    // Route used for the quote (`LPOracleCodes.ROUTE_*`).
    uint8 used;
    // Route whose value serves the price: the lower route during a disagreement (`SPEC-ORC-017`).
    uint8 chosen;
    // Uncapped quote q_i, valuation price v_i and disagreement price w_i, 8 decimals.
    uint256 quote;
    uint256 price;
    uint256 lowerPrice;
    // Timestamps of the quote route and of the chosen route.
    uint64 updatedAt;
    uint64 chosenAt;
    // The two valid routes disagree.
    bool disagree;
    // Both routes are Stale and the first second both failed (`SPEC-ORC-013`).
    bool bothStale;
    uint64 staleAt;
    // Token reason bitmap.
    uint32 reasons;
    // Slot the standby replaces (`RouteSlot` ordinal) and the route version read.
    uint8 replaced;
    uint64 version;
    // Primary-versus-alternate tolerance T_i, bps.
    uint16 tolerance;
    // Second source in force, the pinned decimals and bounds of an oracle-network source, and its evaluation.
    SecondSource second;
    uint8 secondDecimals;
    int256 secondMinAnswer;
    int256 secondMaxAnswer;
    uint256 secondValue;
    bool secondValid;
    bool confirmed;
}

/// @notice The market-wide part of the configuration this evaluation applies.
/// @custom:spec REQ-ORACLE-017, REQ-ORACLE-083, REQ-ORACLE-099
struct ConfigEval {
    // The configuration was read and decoded.
    bool ok;
    uint256 marketId;
    uint32 twapWindow;
    uint16 consistencyToleranceBps;
    uint16 maxQuoteChangeBps;
    uint256 usdBandLow;
    uint256 usdBandHigh;
    uint32 cachedWindow;
    uint32 disagreementPauseMax;
    uint32 graceDuration;
    address sequencerFeed;
    uint32 sequencerGracePeriod;
}

/// @notice Sequencer gate of this evaluation (`SPEC-ORC-021`).
/// @custom:spec SPEC-ORC-021, REQ-ORACLE-099
struct SequencerEval {
    bool up;
    bool down;
    bool unknown;
    bool inGrace;
    bool ready;
    uint64 startedAt;
}

/// @notice One evaluation of the market: what every view and `poke()` computes with the same code in a block.
/// @custom:spec REQ-ORACLE-016, REQ-ORACLE-026, REQ-ORACLE-042, SPEC-ORC-012, SPEC-ORC-013, SPEC-ORC-015, SPEC-ORC-016, SPEC-ORC-017
struct Evaluation {
    ConfigEval cfg;
    TokenEval[] tokens;
    // Quote and valuation vectors in pool order.
    uint256[] quotes;
    uint256[] prices;
    // The market is failed (`REQ-ORACLE-017`).
    bool failed;
    // Some token's route version differs from the stored one (`REQ-ORACLE-095`).
    bool versionChanged;
    // Some token disagrees (`SPEC-ORC-016` D).
    bool disagreeing;
    // The quote-change cap holds the market Cached for this block (`REQ-ORACLE-103`).
    bool quoteCapped;
    // S_ts is defined.
    bool hasStaleStart;
    PriceState state;
    uint256 reasons;
    uint256 fresh;
    uint256 lower;
    uint256 served;
    uint64 servedUpdatedAt;
    uint64 staleStart;
    uint64 failureStart;
    uint64 cachedUntil;
    uint64 disagreeSince;
    uint256 consistencyDeviationBps;
    SequencerEval seq;
    bool pauseActive;
    bool disagreementExpired;
    bool alternatePastBorrowAge;
    bool liquidationPaused;
    bool borrowAllowed;
    bool inGrace;
    uint64 graceEndsAt;
    uint32 borrowMaxAge;
    uint32 liquidationMaxAge;
}
