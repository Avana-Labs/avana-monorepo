// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

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
