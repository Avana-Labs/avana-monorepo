// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteSlot} from "./RouteSlot.sol";

/// @notice Per-token part of an LPOracle price-state report.
/// @dev Prices are 8-decimal USD per whole token; ages and timestamps are seconds.
struct TokenPriceView {
    address token;
    uint32 reasons;
    // Route used for the quote: 0 None, 1 Primary, 2 Alternate.
    uint8 routeUsed;
    // Uncapped quote q_i (8 decimals).
    uint256 quote;
    // Valuation price v_i = q_i after the stable ceiling (8 decimals).
    uint256 valuationPrice;
    // Quote timestamp t_i, the oldest leg timestamp of the route used (seconds).
    uint64 updatedAt;
    // Primary route value (8 decimals, 0 when unreadable).
    uint256 primaryValue;
    // Age of the primary route in seconds (type(uint64).max when unreadable).
    uint64 primaryAge;
    // Alternate route value (8 decimals, 0 when unreadable).
    uint256 alternateValue;
    // Age of the alternate route in seconds (type(uint64).max when unreadable).
    uint64 alternateAge;
    // Informational agreement deviation floor(|p - b| * 1e4 / min(p, b)) in bps.
    uint256 deviationBps;
    // Feed-agreement tolerance T_i in bps (the stored value).
    uint16 feedAgreementToleranceBps;
    // Second-source value (8 decimals, 0 when unreadable or not configured).
    uint256 secondSourceValue;
    // floor(|q - s| * 1e4 / min(q, s)) in bps (type(uint256).max when unreadable).
    uint256 secondSourceDeviationBps;
    // Chainlink aggregator proxies of the selected route, in leg order.
    address[2] legFeeds;
    // Original Chainlink `updatedAt` of each leg (seconds).
    uint64[2] legUpdatedAt;
    // borrowPriceMaxAge of each leg (seconds).
    uint32[2] legBorrowPriceMaxAge;
    // liquidationPriceMaxAge of each leg (seconds).
    uint32[2] legLiquidationPriceMaxAge;
    // Slot the token's standby route replaces (None when both recorded routes are in force).
    RouteSlot replaced;
    // MarketRegistry.priceRouteVersion(token) read in this evaluation.
    uint64 routeVersion;
}
