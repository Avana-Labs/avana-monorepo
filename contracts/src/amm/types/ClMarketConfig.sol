// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Integration-specific configuration of a concentrated-liquidity market, stored by `bindMarket`.
/// @dev Read on-chain at listing and never changed. `fee` is the pool's fee tier (Uniswap v3: the pool key; Slipstream:
/// 0, since its fee is set per pool by fee modules, can change at any block and is read live from `pool.fee()`); `tickSpacing` is read
/// from the pool; `tickLower` and `tickUpper` are the exact range. `positionManager` and `factory` are the pair the
/// market is bound to (Slipstream runs four generations on Base). `maxLiquidityPerTick` bounds the rounding excess
/// `L / (S * 2^96)` of AMM-A3e at listing.
/// @custom:spec REQ-AMM-V3-002, REQ-AMM-SLIP-002, REQ-AMM-CORE-004, Q-370
struct ClMarketConfig {
    // Pool address.
    address pool;
    // Position manager the market's positions belong to.
    address positionManager;
    // Factory that created the pool.
    address factory;
    // token0.
    address token0;
    // token1.
    address token1;
    // Uniswap v3: the fee tier at listing, pips. Slipstream: always 0 (the fee is dynamic; the LPVault never reads it).
    uint24 fee;
    // Pool tick spacing.
    int24 tickSpacing;
    // Exact range lower tick.
    int24 tickLower;
    // Exact range upper tick.
    int24 tickUpper;
    // Pool maxLiquidityPerTick.
    uint128 maxLiquidityPerTick;
}
