// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Constructor arguments every swap route shares, fixed as immutables at deployment.
/// @dev The constructor reverts `InvalidRouteConfig` unless every address but the three factories is non-zero,
/// `lpVaultSwap != aaveAdapter`, `tokenIn != tokenOut`, the Lock's members are exactly `aaveAdapter` and `lpVaultSwap`,
/// and `tokenClassMask` sets only bits 1 (stable), 2 (correlated) and 3 (volatile) and at least one of them. The
/// factories are the chain's pinned pool factories from the address book; a zero factory means the chain has none of
/// that family, and a hop on a pool of that family is then refused.
/// @custom:spec REQ-ROUTE-005, REQ-ROUTE-007, REQ-ROUTE-016, Q-379
struct RouteConfig {
    // The chain's LPVaultSwap proxy; the only caller of `swap`.
    address lpVaultSwap;
    // The chain's Lock.
    address lock;
    // The chain's AaveAdapter proxy; the second Lock holder a route accepts.
    address aaveAdapter;
    // Input token: a released pool token.
    address tokenIn;
    // Output token: the debt asset.
    address tokenOut;
    // Token classes the route was tested for: bit c set for class c (1 stable, 2 correlated, 3 volatile).
    uint8 tokenClassMask;
    // The chain's pinned Uniswap v3 factory; every Uniswap v3 hop pool is its `getPool(token0, token1, fee)`.
    address uniswapV3Factory;
    // The chain's pinned Aerodrome Slipstream factory; every Slipstream hop pool is its `getPool(t0, t1, tickSpacing)`.
    address slipstreamFactory;
    // The chain's pinned Curve StableSwap-NG factory; every Curve hop pool is one of its pools, at the hop's indices.
    address curveFactory;
}
