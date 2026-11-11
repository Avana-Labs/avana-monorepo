// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Usability of one swap route a liquidation of the previewed account would use.
/// @dev One entry per (pool token other than the debt asset, slot): `token` is the pool token sold, `debtAsset` the
/// asset bought, `routeKind` 0 the primary and 1 the backup, `usable` the value `MarketRegistry.getRoute(marketId,
/// token, debtAsset, routeKind)` returns. A pool token equal to the debt asset needs no route and has no entry.
/// @custom:spec REQ-LENS-016, Q-379
struct RouteStatus {
    address token;
    address debtAsset;
    uint8 routeKind;
    bool usable;
}
