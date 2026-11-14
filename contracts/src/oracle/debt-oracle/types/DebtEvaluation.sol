// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../../types/PriceState.sol";
import {RouteSlot} from "../../../types/RouteSlot.sol";

/// @notice Classification of one leg or route read by the DebtOracle (`REQ-ORACLE-001` to `REQ-ORACLE-004`).
/// @dev `Valid` passes every condition of `REQ-ORACLE-002`; `Stale` fails only the age condition; `Invalid` fails any
/// other condition; `Error` is a revert, a short return or a failed decode (legs only; a route with an `Error` leg is
/// `Invalid`). Only `Stale` counts as a source-timestamp failure. Ordinal values are fixed.
/// @custom:spec REQ-ORACLE-001, REQ-ORACLE-003, REQ-ORACLE-004
enum ReadStatus {
    Valid,
    Stale,
    Invalid,
    Error
}

/// @notice One Chainlink leg as one DebtOracle evaluation read it.
/// @dev `roundId`, `updatedAt` and `answer` are meaningful when `status != Error`. The age limits come from the
/// ParameterStore feed record (`SPEC-ORC-019`).
/// @custom:spec REQ-ORACLE-001, REQ-ORACLE-002, REQ-ORACLE-031, SPEC-ORC-019
struct LegRead {
    // Chainlink aggregator proxy.
    address feed;
    // Leg classification.
    ReadStatus status;
    // Proxy round identifier of `latestRoundData()`.
    uint80 roundId;
    // Chainlink `updatedAt`, seconds.
    uint64 updatedAt;
    // Raw signed answer.
    int256 answer;
    // `feedHeartbeat + heartbeatMargin`, seconds.
    uint64 maxAge;
    // Pinned decimals of the feed record.
    uint8 pinnedDecimals;
    // Pinned minAnswer and maxAnswer (raw units, exclusive bounds).
    int256 minAnswer;
    int256 maxAnswer;
    // Borrow and liquidation age limits of the feed record, seconds.
    uint32 borrowMaxAge;
    uint32 liquidationMaxAge;
}

/// @notice One route (primary or alternate) as one DebtOracle evaluation read it.
/// @dev `value` and `updatedAt` follow `SPEC-ORC-002` over every decoded leg; `staleFrom` is `SPEC-ORC-013`'s first
/// failing second of a `Stale` route.
/// @custom:spec SPEC-ORC-002, SPEC-ORC-013, REQ-ORACLE-004
struct RouteRead {
    // One or two legs in multiplication order.
    uint8 legCount;
    // Route classification (never Error).
    ReadStatus status;
    // Route value, 8-decimal USD per whole token; 0 when a leg did not decode.
    uint256 value;
    // Oldest leg timestamp.
    uint64 updatedAt;
    // min over the Stale legs of (updatedAt + maxAge) + 1.
    uint64 staleFrom;
    // The legs.
    LegRead[2] legs;
}

/// @notice Everything one DebtOracle evaluation computes, shared by every view and `poke()`.
/// @dev Built by `DebtOracleEvaluation._evaluate` from the reads of one block; `poke()` stores from it.
/// @custom:spec REQ-ORACLE-092, REQ-ORACLE-093, SPEC-ORC-013, SPEC-ORC-015, SPEC-ORC-016, SPEC-ORC-018
struct DebtEvaluation {
    // Price state and reason bitmap.
    PriceState state;
    uint256 reasons;
    bool failed;
    // Configuration read in this evaluation.
    bool routeVersionRead;
    uint64 routeVersion;
    RouteSlot replaced;
    uint16 toleranceBps;
    bool cachedWindowRead;
    uint32 cachedWindow;
    uint32 disagreementPauseMax;
    uint32 graceDuration;
    // Stress rise read in this evaluation, clamped to [.., 5,000]; the last writing call's value when the read failed.
    bool stressRiseRead;
    uint16 stressRiseBps;
    // Routes and quote.
    RouteRead[2] routes;
    RouteSlot routeUsed;
    uint256 quote;
    uint64 quoteUpdatedAt;
    bool disagree;
    // Failure start (SPEC-ORC-013).
    bool sourceTimestampFailure;
    uint64 staleAt;
    uint64 failureStart;
    // Disagreement windows (SPEC-ORC-016); `disagreeSince` is the stored value, 0 after a version change.
    uint64 disagreeSince;
    bool pauseActive;
    bool disagreementExpired;
    // Served price and its age.
    uint256 accepted;
    uint64 acceptedUpdatedAt;
    uint256 served;
    uint64 servedUpdatedAt;
    // The route whose value is served and whose legs and timestamp are reported: the quote route, or while Drifting the
    // route of the larger value; None when the accepted price is served (failed, or Drifting below it).
    RouteSlot servedRoute;
    uint32 borrowPriceMaxAge;
    uint32 liquidationPriceMaxAge;
    bool alternatePastBorrowAge;
    // Sequencer gate (SPEC-ORC-021).
    bool sequencerDown;
    bool sequencerUnknown;
    bool sequencerGrace;
    // SPEC-ORC-021 ready and, on an L2, the served round newer than the restart: the sequencer term of borrowAllowed.
    bool sequencerReady;
    uint64 sequencerGraceEndsAt;
    // Grace window (REQ-ORACLE-034).
    uint64 recoveredAt;
    uint64 graceEndsAt;
    bool inGrace;
    // Second source (SPEC-ORC-020): its value, validity and tolerance, read before the served price so that a
    // Drifting asset's higher route counts only when the second source confirms it.
    bool confirmed;
    bool secondValid;
    uint256 secondValue;
    uint16 secondToleranceBps;
    // Gates.
    bool liquidationPaused;
    bool borrowAllowed;
}
