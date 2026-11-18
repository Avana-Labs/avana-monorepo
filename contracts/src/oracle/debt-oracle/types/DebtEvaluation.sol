// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState, RouteSlot} from "../../../types/OracleTypes.sol";

/// @notice Classification of one leg or route read by the DebtOracle; ordinal values are fixed.
enum ReadStatus {
    Valid,
    Stale,
    Invalid,
    Error
}

/// @notice One Chainlink leg as one DebtOracle evaluation read it.
struct LegRead {
    address feed;
    ReadStatus status;
    uint80 roundId;
    uint64 updatedAt;
    int256 answer;
    // Heartbeat plus margin, seconds.
    uint64 maxAge;
    uint8 pinnedDecimals;
    // Exclusive bounds, raw units.
    int256 minAnswer;
    int256 maxAnswer;
    uint32 borrowMaxAge;
    uint32 liquidationMaxAge;
}

/// @notice One route (primary or alternate) as one DebtOracle evaluation read it.
struct RouteRead {
    uint8 legCount;
    // Never Error.
    ReadStatus status;
    // 8-decimal USD per whole token; 0 when a leg did not decode.
    uint256 value;
    uint64 updatedAt;
    // First second the route was Stale.
    uint64 staleFrom;
    LegRead[2] legs;
}

/// @notice Everything one DebtOracle evaluation computes, shared by every view and `poke()`.
struct DebtEvaluation {
    PriceState state;
    uint256 reasons;
    bool failed;
    bool routeVersionRead;
    uint64 routeVersion;
    RouteSlot replaced;
    uint16 toleranceBps;
    bool cachedWindowRead;
    uint32 cachedWindow;
    uint32 disagreementPauseMax;
    uint32 graceDuration;
    // Stress rise, capped; the stored value when the read failed.
    bool stressRiseRead;
    uint16 stressRiseBps;
    RouteRead[2] routes;
    RouteSlot routeUsed;
    uint256 quote;
    uint64 quoteUpdatedAt;
    bool disagree;
    bool sourceTimestampFailure;
    uint64 staleAt;
    uint64 failureStart;
    // Stored value, 0 after a version change.
    uint64 disagreeSince;
    bool pauseActive;
    bool disagreementExpired;
    uint256 accepted;
    uint64 acceptedUpdatedAt;
    uint256 served;
    uint64 servedUpdatedAt;
    // None when the accepted price is served.
    RouteSlot servedRoute;
    uint32 borrowPriceMaxAge;
    uint32 liquidationPriceMaxAge;
    bool alternatePastBorrowAge;
    bool sequencerDown;
    bool sequencerUnknown;
    bool sequencerGrace;
    // Sequencer ready and the served round newer than its restart.
    bool sequencerReady;
    uint64 sequencerGraceEndsAt;
    uint64 recoveredAt;
    uint64 graceEndsAt;
    bool inGrace;
    bool confirmed;
    bool liquidationPaused;
    bool borrowAllowed;
}
