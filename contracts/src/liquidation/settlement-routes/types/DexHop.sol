// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Pool family of one `DexPath` hop.
/// @dev `ConcentratedLiquidity` covers Uniswap v3 and Aerodrome Slipstream pools: both expose
/// `swap(recipient, zeroForOne, amountSpecified, sqrtPriceLimitX96, data)` and pay through `uniswapV3SwapCallback`.
/// `CurveStableSwap` is a Curve StableSwap-NG plain pool called with `exchange(i, j, dx, 0)`. `CurveLegacy` is a legacy
/// (pre-NG) Curve plain pool on the chain's pinned list, called with the same `exchange(i, j, dx, 0)`, which some
/// legacy pools answer with no return value; every hop's output is measured as the route's balance rise.
/// @custom:spec REQ-ROUTE-002, REQ-ROUTE-009, REQ-ROUTE-013, REQ-ROUTE-046
enum HopKind {
    ConcentratedLiquidity,
    CurveStableSwap,
    CurveLegacy
}

/// @notice One fixed hop of a `DexPath` (or of the DEX part of a `WrapperThenDex` route).
/// @dev The hop's input token is the previous hop's `tokenOut` (the first hop takes the route's path start). The
/// constructor checks the hop against the pool: a concentrated-liquidity pool's `{token0, token1}` equals
/// `{input, tokenOut}` (the swap direction is derived from it); a Curve pool's (StableSwap-NG or legacy) `coins(i)` is
/// the input and `coins(j)` is `tokenOut`, with `i != j`, both non-negative. `i` and `j` are 0 for a
/// concentrated-liquidity hop.
/// @custom:spec REQ-ROUTE-002, REQ-ROUTE-043, REQ-ROUTE-046
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
