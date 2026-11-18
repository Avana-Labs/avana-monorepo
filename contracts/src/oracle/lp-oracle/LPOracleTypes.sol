// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {PriceState} from "../../types/PriceState.sol";
import {SecondSource} from "../../types/SecondSource.sol";

/// @title LPOracleCodes
/// @notice Leg and route classes, route slots, reason bits and `checkConfig` bits of the LPOracle.
library LPOracleCodes {
    uint8 internal constant VALID = 0;
    uint8 internal constant STALE = 1;
    uint8 internal constant INVALID = 2;
    uint8 internal constant ERROR = 3;

    // Route used for a token's quote: 0 None, 1 Primary, 2 Alternate.
    uint8 internal constant ROUTE_NONE = 0;
    uint8 internal constant ROUTE_PRIMARY = 1;
    uint8 internal constant ROUTE_ALTERNATE = 2;

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
    uint256 internal constant DECIMALS_UNVERIFIED = 1 << 19;

    /// @dev Bits 2 to 6 make a market that is not failed Drifting.
    uint256 internal constant DRIFTING_BITS = (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6);

    /// @dev Bits 2 to 6, 11, 12 and 16 are not evaluated, and are 0, when the market is failed.
    uint256 internal constant NOT_EVALUATED_WHEN_FAILED = DRIFTING_BITS | (1 << 11) | (1 << 12) | (1 << 16);

    uint32 internal constant TOKEN_NO_ROUTE = 1 << 0;
    uint32 internal constant TOKEN_DISAGREE = 1 << 1;
    uint32 internal constant TOKEN_ON_ALTERNATE = 1 << 2;
    uint32 internal constant TOKEN_ON_STANDBY = 1 << 3;
    uint32 internal constant TOKEN_SECOND_SOURCE_DISAGREE = 1 << 4;
    uint32 internal constant TOKEN_SECOND_SOURCE_UNAVAILABLE = 1 << 5;

    // `checkConfig` bits; bits 16 and above belong to the pricing module's `listingChecks`.
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

/// @notice One leg of a route in force: its pinned settings and what this evaluation read.
struct LegEval {
    address feed;
    uint8 pinnedDecimals;
    int256 minAnswer;
    int256 maxAnswer;
    // Heartbeat plus margin, seconds.
    uint64 maxAge;
    uint32 borrowAge;
    uint32 liquidationAge;
    uint8 status;
    // latestRoundData() returned decodable data, recorded in `seen`.
    bool decoded;
    uint80 roundId;
    int256 answer;
    uint64 updatedAt;
    // decimals() read (0 when unreadable).
    uint8 readDecimals;
}

/// @notice One route in force and its value, timestamp and class in this evaluation.
struct RouteEval {
    uint8 legCount;
    uint8 status;
    // Route value, 8 decimals (0 when not computable).
    uint256 value;
    // The oldest leg's timestamp.
    uint64 updatedAt;
    // First second a Stale route was stale.
    uint64 staleFrom;
    LegEval[2] legs;
}

struct TokenEval {
    // Primary (0) and alternate (1) routes in force.
    RouteEval[2] routes;
    uint8 used;
    // Route whose value serves the price: the lower route during a disagreement.
    uint8 chosen;
    // Uncapped quote, valuation price and disagreement price, 8 decimals.
    uint256 quote;
    uint256 price;
    uint256 lowerPrice;
    uint64 updatedAt;
    uint64 chosenAt;
    bool disagree;
    // Both routes are Stale, and the first second both were.
    bool bothStale;
    uint64 staleAt;
    uint32 reasons;
    // `RouteSlot` ordinal the standby replaces.
    uint8 replaced;
    uint64 version;
    // Primary-versus-alternate tolerance, bps.
    uint16 tolerance;
    SecondSource second;
    uint8 secondDecimals;
    int256 secondMinAnswer;
    int256 secondMaxAnswer;
    uint256 secondValue;
    bool secondValid;
    bool confirmed;
}

struct ConfigEval {
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

struct SequencerEval {
    bool up;
    bool down;
    bool unknown;
    bool inGrace;
    bool ready;
    uint64 startedAt;
}

/// @notice One evaluation of the market, computed by the same code for every view and `poke()`.
struct Evaluation {
    ConfigEval cfg;
    TokenEval[] tokens;
    uint256[] quotes;
    uint256[] prices;
    bool failed;
    bool versionChanged;
    bool disagreeing;
    // The quote-change cap holds the market Cached for this block.
    bool quoteCapped;
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
    // Token decimals: verification time relied on, and for a failed check the token and what it read.
    uint64 decimalsCheckedAt;
    bool decimalsMismatch;
    uint8 decimalsToken;
    uint8 decimalsRead;
    bool decimalsReadable;
}

/// @notice Concentrated-liquidity detail of an LPOracle evaluation, returned by `ILPOracleCL.getClPriceState()`.
/// @dev One tick is a price ratio of 1.0001, about 1 bp.
struct ClPriceStateView {
    int24 tickLower;
    int24 tickUpper;
    // Oracle sqrt price before the clamp, Q64.96.
    uint160 sqrtPriceOracleX96;
    // Oracle sqrt price after the clamp to the range, Q64.96 (the composition input).
    uint160 sqrtPriceUsedX96;
    bool clamped;
    // Pool TWAP mean tick over twapWindow, rounded toward negative infinity.
    int24 meanTick;
    // Oracle-implied tick from the uncapped quotes.
    int24 tickRef;
    // |meanTick - tickRef| in ticks.
    uint24 tickDeviation;
    // TWAP tolerance in ticks (`OracleConfig.consistencyToleranceBps`).
    uint24 twapToleranceTicks;
    uint16 observationCardinality;
}

/// @notice Arguments of `initialize`.
/// @dev The MarketRegistry does not yet hold the market, so its identity comes from these arguments.
struct InitParams {
    // Avana timelock; must equal the implementation's TIMELOCK.
    address timelock;
    address parameterStore;
    address marketRegistry;
    // MarketRegistry identifier the market will be registered under.
    uint256 marketId;
    // The market's AMM integration (LPVault).
    address integration;
    // Stable-ceiling flag per token, in pool order.
    bool[] isUsdStable;
    string description;
    uint32 pokeMinGas;
    // Configuration validated by checkConfig and evaluated for the seed.
    OracleConfig config;
    // The pricing module's market encoding (pool, range and unit exponent).
    bytes market;
}

/// @notice The immutable logic contracts of one LPOracle implementation, each run by delegatecall.
/// @dev `initLogic` and `listingLogic` may be the same address.
// The struct's name keeps its LPOracle prefix, as every LPOracle type does.
// forge-lint: disable-next-item(pascal-case-struct)
struct LPOracleLogicSet {
    address pokeLogic;
    // Runs `initializeMarket`.
    address initLogic;
    // Runs `checkConfig`.
    address listingLogic;
    address viewLogic;
}
