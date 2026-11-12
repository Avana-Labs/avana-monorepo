// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Constructor arguments every swap route shares, fixed as immutables at deployment.
/// @dev The constructor reverts `InvalidRouteConfig` unless every address but the three factories is non-zero,
/// `lpVaultSwap != aaveAdapter`, `tokenIn != tokenOut`, the Lock's members are exactly `aaveAdapter` and `lpVaultSwap`,
/// and `tokenClassMask` sets only bits 1 (stable), 2 (correlated) and 3 (volatile) and at least one of them. The
/// factories are the chain's pinned pool factories from the address book; a zero factory means the chain has none of
/// that family, and a hop on a pool of that family is then refused. `curveLegacyPools` is the chain's pinned list of
/// legacy (pre-NG) Curve pools from the address book, at most `MAX_CURVE_LEGACY_POOLS` (8) entries: legacy pools have
/// no factory to pin, so each one is pinned by address after review; an empty list refuses every legacy Curve hop. A
/// route that has no DEX hop ignores it.
/// @custom:spec REQ-ROUTE-005, REQ-ROUTE-007, REQ-ROUTE-016, REQ-ROUTE-045, Q-379
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
    // The chain's pinned legacy Curve pools; every legacy Curve hop pool is one of them (at most 8 entries).
    address[] curveLegacyPools;
}
