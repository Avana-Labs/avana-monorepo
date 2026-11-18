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

/// @notice Constructor arguments every swap route shares, fixed as immutables at deployment.
/// @dev A zero factory or an empty `curveLegacyPools` refuses every hop of that pool family.
struct RouteConfig {
    address lpVaultSwap;
    address lock;
    address aaveAdapter;
    address tokenIn;
    // The debt asset.
    address tokenOut;
    // Token classes the route was tested for: bit c set for class c (1 stable, 2 correlated, 3 volatile).
    uint8 tokenClassMask;
    address uniswapV3Factory;
    address slipstreamFactory;
    address curveFactory;
    address[] curveLegacyPools;
}

/// @notice Unwrap or redeem step of a `WrapperThenDex` route.
enum WrapperKind {
    Erc4626Redeem,
    UsdsToDai
}

/// @notice The unwrap step a `WrapperThenDex` route runs before its DEX hops.
/// @dev When `underlying` is the debt asset the route has no hops.
struct WrapperStep {
    WrapperKind kind;
    // The ERC-4626 vault (the input token itself) or the DAI/USDS converter.
    address wrapper;
    // Token the step produces: the vault's asset, or DAI.
    address underlying;
}
