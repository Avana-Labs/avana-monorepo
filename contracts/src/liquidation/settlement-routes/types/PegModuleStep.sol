// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Peg module of a `PegModule` route.
/// @dev `Gsm`: a GHO Stability Module whose underlying is a static aToken of the input token (Ethereum, backup slot of
/// a GHO debt reserve only). `LitePsm`: the Sky LitePSM, buying its gem (USDC) with DAI, optionally after the DAI/USDS
/// converter turns USDS into DAI.
/// @custom:spec REQ-ROUTE-002, REQ-ROUTE-011, REQ-ROUTE-012
enum PegModuleKind {
    Gsm,
    LitePsm
}

/// @notice The legs of a `PegModule` route.
/// @dev The constructor reverts `InvalidRouteConfig` unless: for `Gsm`, `wrapper` is a static aToken whose `asset()` is
/// the input token, `intermediate == wrapper`, the GSM's `UNDERLYING_ASSET()` is `wrapper` and its `GHO_TOKEN()` is the
/// output token; for `LitePsm`, the output token has at most 18 decimals, and either `wrapper` (the DAI/USDS converter)
/// and `intermediate` (DAI) are both zero (DAI input) or both non-zero and distinct from the input and output tokens
/// (USDS input).
/// @custom:spec REQ-ROUTE-003, REQ-ROUTE-011, REQ-ROUTE-012
struct PegModuleStep {
    // Peg module kind.
    PegModuleKind kind;
    // The GSM or the LitePSM.
    address module;
    // The static aToken (GSM) or the DAI/USDS converter (LitePSM with USDS input); zero for LitePSM with DAI input.
    address wrapper;
    // The token held between legs: the static aToken shares (GSM) or DAI (USDS input); zero for DAI input.
    address intermediate;
}
