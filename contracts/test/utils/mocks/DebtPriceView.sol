// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState, RouteSlot} from "../../../src/types/OracleTypes.sol";

/// @notice Full price-state report of one DebtOracle, returned by `getPriceState()`.
/// @dev Unreadable route values are 0 and unreadable ages `type(uint64).max`.
struct DebtPriceView {
    PriceState state;
    // The DebtOracle's `R_*` bits.
    uint256 reasons;
    // Served price, always >= 1.
    int256 answer;
    uint64 servedUpdatedAt;
    uint64 servedAge;
    uint256 acceptedAnswer;
    uint64 acceptedUpdatedAt;
    RouteSlot routeUsed;
    // Uncapped quote (0 when failed).
    uint256 quote;
    uint256 primaryValue;
    uint64 primaryAge;
    uint256 alternateValue;
    uint64 alternateAge;
    uint256 deviationBps;
    uint16 feedAgreementToleranceBps;
    // Slot the standby route replaces (None when not switched).
    RouteSlot replaced;
    uint64 routeVersion;
    // Aggregator proxies of the served route; address(0) for an unused slot.
    address[2] legFeeds;
    uint64[2] legUpdatedAt;
    uint32[2] legBorrowPriceMaxAge;
    // Capped at borrowPriceMaxAge on an alternate route.
    uint32[2] legLiquidationPriceMaxAge;
    // 0 when not failed.
    uint64 failureStart;
    // 0 when not failed.
    uint64 cachedUntil;
    uint64 disagreeSince;
    bool disagreementPauseActive;
    bool disagreementExpired;
    // True when not Live, a serving alternate is past its borrow age, or the sequencer is down.
    bool liquidationPaused;
    // Source timestamp of the first fresh update after the last Expired outage (0 if none).
    uint64 recoveredAt;
    uint64 graceEndsAt;
    bool inGrace;
    // 0 when the accepted price is served.
    uint32 borrowPriceMaxAge;
    // 0 when the accepted price is served.
    uint32 liquidationPriceMaxAge;
    // Capped; the stored value on a failed read.
    uint16 debtStressRiseBps;
    // Price served once Expired, rounded up.
    uint256 stressAnswer;
    // Live, sequencer ready, second source confirmed and the served price within borrowPriceMaxAge.
    bool borrowAllowed;
}
