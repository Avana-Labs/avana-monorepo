// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Integration-specific configuration of a concentrated-liquidity market, stored by `bindMarket`.
/// @dev Read on-chain at listing and never changed.
struct ClMarketConfig {
    address pool;
    address positionManager;
    address factory;
    address token0;
    address token1;
    // Uniswap v3: the fee tier, pips. Slipstream: always 0 (its fee is dynamic).
    uint24 fee;
    int24 tickSpacing;
    int24 tickLower;
    int24 tickUpper;
    uint128 maxLiquidityPerTick;
}
