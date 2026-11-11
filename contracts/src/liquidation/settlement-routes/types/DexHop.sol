// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Pool family of one `DexPath` hop.
/// @dev `ConcentratedLiquidity` covers Uniswap v3 and Aerodrome Slipstream pools: both expose
/// `swap(recipient, zeroForOne, amountSpecified, sqrtPriceLimitX96, data)` and pay through `uniswapV3SwapCallback`.
/// `CurveStableSwap` is a Curve StableSwap-NG plain pool called with `exchange(i, j, dx, 0)`.
/// @custom:spec REQ-ROUTE-002, REQ-ROUTE-009, REQ-ROUTE-013
enum HopKind {
    ConcentratedLiquidity,
    CurveStableSwap
}

/// @notice One fixed hop of a `DexPath` (or of the DEX part of a `WrapperThenDex` route).
/// @dev The hop's input token is the previous hop's `tokenOut` (the first hop takes the route's path start). The
/// constructor checks the hop against the pool: a concentrated-liquidity pool's `{token0, token1}` equals
/// `{input, tokenOut}` (the swap direction is derived from it); a Curve pool's `coins(i)` is the input and `coins(j)`
/// is `tokenOut`, with `i != j`, both non-negative. `i` and `j` are 0 for a concentrated-liquidity hop.
/// @custom:spec REQ-ROUTE-002, REQ-ROUTE-043
struct DexHop {
    // Pool family.
    HopKind kind;
    // The fixed pool; listed in `dependencies()`.
    address pool;
    // Token the hop produces; the last hop's is the debt asset.
    address tokenOut;
    // Curve index of the input coin.
    int128 i;
    // Curve index of the output coin.
    int128 j;
}
