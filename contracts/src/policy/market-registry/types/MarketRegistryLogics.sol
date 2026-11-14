// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The six immutable logic contracts the MarketRegistry delegatecalls for its write bodies.
/// @dev Each is built with the same `MarketRegistryImmutables` as the MarketRegistry implementation; the constructor
/// checks every `logicConfig()`, so a new logic contract is part of a new implementation and waits the normal delay.
/// @custom:spec REQ-CONFIG-001, REQ-CONFIG-002
struct MarketRegistryLogics {
    // Hubs, integrations, First-Loss Reserves, cross-Hub lines, the flash source, CDP Spokes and debt reserves.
    address hubs;
    // Tokens, price sources and market listing.
    address listing;
    // Market activation, cancellation and offboarding.
    address activation;
    // Swap routes and the standby switch.
    address routes;
    // Pause state and reason, address freeze and breakers.
    address safety;
    // Wind-down, close, settlement reserve and the credit-line registry.
    address windDown;
}
