// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteSlot} from "./RouteSlot.sol";

/// @notice Per-token part of an LPOracle price-state report: route in use, quote, valuation price, agreement tolerance,
/// second-source agreement, standby slot and route version, and the feed address, source timestamp and age limits of
/// every Chainlink leg of the route in use.
/// @dev Prices are 8-decimal USD per whole token; ages and timestamps are seconds. A route value or age that cannot be
/// read is reported as 0 and `type(uint64).max`. The `leg*` arrays list the legs of the route in use (one or two); an
/// unused slot is `address(0)` and 0. `reasons` is the token's reason bitmap: bit 0 NO_ROUTE, 1 DISAGREE,
/// 2 ON_ALTERNATE, 3 ON_STANDBY, 4 SECOND_SOURCE_DISAGREE, 5 SECOND_SOURCE_UNAVAILABLE. The RiskModule checks each leg
/// against `ParameterStore.borrowPriceMaxAge(feed)`, LPVaultSwap against `liquidationPriceMaxAge(feed)`, and the Lens
/// reports both limits.
/// @custom:spec REQ-ORACLE-042, REQ-ORACLE-094, REQ-ORACLE-100, SPEC-ORC-015, SPEC-ORC-020, Q-182, Q-229, Q-248, Q-322, Q-323
struct TokenPriceView {
    // Pool token.
    address token;
    // Token reason bitmap (see @dev).
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
    // Slot the token's standby route replaces in MarketRegistry.activePriceRoutes (None when both recorded routes are in
    // force).
    RouteSlot replaced;
    // MarketRegistry.priceRouteVersion(token) read in this evaluation.
    uint64 routeVersion;
}
