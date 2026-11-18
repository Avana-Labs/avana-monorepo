// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteSlot} from "../../../types/RouteSlot.sol";
import {IssuerProbe} from "./IssuerProbe.sol";

/// @notice Listed token definition (pool token or debt asset).
/// @dev Empty alternate and standby routes mark a monitoring-only listing (a fixed-price debt asset).
struct TokenDef {
    bool listed;
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
    // Issuer-action probe the RiskModule runs for this token (`UsdtFeeRateAndPaused` runs both reads).
    IssuerProbe issuerProbe;
    // Peg module (GSM or PSM) of the token that a backup swap route must avoid, or address(0).
    address pegModule;
}
