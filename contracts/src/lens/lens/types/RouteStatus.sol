// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Usability of one swap route a liquidation of the previewed account would use.
/// @dev `routeKind` 0 is the primary, 1 the backup; a pool token equal to the debt asset has no entry.
struct RouteStatus {
    address token;
    address debtAsset;
    uint8 routeKind;
    bool usable;
}
