// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Peg module of a `PegModule` route.
enum PegModuleKind {
    Gsm,
    LitePsm
}

/// @notice The legs of a `PegModule` route.
struct PegModuleStep {
    PegModuleKind kind;
    address module;
    // The static aToken (GSM) or the DAI/USDS converter (USDS input); zero for DAI input.
    address wrapper;
    // The token held between legs: the static aToken shares (GSM) or DAI (USDS input); zero for DAI input.
    address intermediate;
}
