// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteSlot} from "../../../types/RouteSlot.sol";
import {IssuerProbe} from "./IssuerProbe.sol";

/// @notice Listed token definition (pool token or debt asset without a fixed-price source).
/// @dev `decimals` is read on-chain at listing. The collateral-factor input, the feed-agreement tolerance and each
/// feed's heartbeat live in the ParameterStore; every feed of the three routes must have a ParameterStore feed
/// definition. The routes in force are `IMarketRegistry.activePriceRoutes(token)`.
/// @custom:spec REQ-CONFIG-017, REQ-CONFIG-018, REQ-CONFIG-021, REQ-CONFIG-025, REQ-MREG-027, Q-248
struct TokenDef {
    // True once listed.
    bool listed;
    // Token decimals.
    uint8 decimals;
    // Approved USD-pegged stablecoin.
    bool isUsdStable;
    // Chainlink aggregator proxies of the primary TOKEN/USD route.
    address[] primaryRoute;
    // Chainlink aggregator proxies of the alternate route.
    address[] alternateRoute;
    // Chainlink aggregator proxies of the pre-approved standby route.
    address[] standbyRoute;
    // Slot the standby currently replaces; None at listing.
    RouteSlot replacedSlot;
    // Issuer-action probe the RiskModule runs for this token.
    IssuerProbe issuerProbe;
    // Peg module (GSM or PSM) of the token that a backup swap route must avoid, or address(0).
    address pegModule;
}
