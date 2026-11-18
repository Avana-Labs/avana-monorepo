// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Pool family of one `DexPath` hop.
/// @dev `ConcentratedLiquidity` covers Uniswap v3 and Aerodrome Slipstream pools.
enum HopKind {
    ConcentratedLiquidity,
    CurveStableSwap,
    CurveLegacy
}

/// @notice One fixed hop of a `DexPath` (or of the DEX part of a `WrapperThenDex` route).
/// @dev The hop's input token is the previous hop's `tokenOut`.
struct DexHop {
    HopKind kind;
    address pool;
    // Token the hop produces; the last hop's is the debt asset.
    address tokenOut;
    // Curve index of the input coin; 0 for a concentrated-liquidity hop.
    int128 i;
    // Curve index of the output coin; 0 for a concentrated-liquidity hop.
    int128 j;
}
