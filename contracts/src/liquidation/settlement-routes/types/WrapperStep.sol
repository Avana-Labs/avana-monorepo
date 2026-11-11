// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Unwrap or redeem step of a `WrapperThenDex` route.
/// @dev `Erc4626Redeem`: the input token is an ERC-4626 vault (a static aToken, a savings-rate token) and the route
/// calls `redeem(amount, route, route)`, which needs no allowance. `UsdsToDai`: the input token is USDS and the route
/// calls the Sky DAI/USDS converter's `usdsToDai(route, amount)` after approving it for exactly `amount`.
/// @custom:spec REQ-ROUTE-002, REQ-ROUTE-010
enum WrapperKind {
    Erc4626Redeem,
    UsdsToDai
}

/// @notice The unwrap step a `WrapperThenDex` route runs before its DEX hops.
/// @dev The constructor reverts `InvalidRouteConfig` unless: for `Erc4626Redeem`, `wrapper` is the route's input token
/// and `underlying` is its `asset()`; for `UsdsToDai`, `wrapper` is non-zero and differs from the input token; in both,
/// `underlying` is non-zero and differs from the input token. When `underlying` is the debt asset the route has no
/// hops.
/// @custom:spec REQ-ROUTE-002, REQ-ROUTE-003
struct WrapperStep {
    // Step kind.
    WrapperKind kind;
    // The contract called: the ERC-4626 vault (the input token itself) or the DAI/USDS converter.
    address wrapper;
    // Token the step produces: the vault's asset, or DAI.
    address underlying;
}
