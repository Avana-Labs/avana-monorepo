// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice A position of a concentrated-liquidity position manager: the 12 fields of `positions(tokenId)`, every one a
/// static ABI word, so this struct decodes exactly the tuple the manager returns. `poolParam` is the Uniswap v3 fee
/// tier (`uint24`) or the Slipstream tick spacing (`int24`, positive), both read as one word.
struct LensClPosition {
    uint96 nonce;
    address operator;
    address token0;
    address token1;
    int24 poolParam;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 feeGrowthInside0LastX128;
    uint256 feeGrowthInside1LastX128;
    uint128 tokensOwed0;
    uint128 tokensOwed1;
}

/// @notice A Uniswap v3 tick: the 8 fields of `ticks(tick)`.
struct LensV3Tick {
    uint128 liquidityGross;
    int128 liquidityNet;
    uint256 feeGrowthOutside0X128;
    uint256 feeGrowthOutside1X128;
    int56 tickCumulativeOutside;
    uint160 secondsPerLiquidityOutsideX128;
    uint32 secondsOutside;
    bool initialized;
}

/// @notice A Slipstream tick: the 10 fields of `ticks(tick)`.
struct LensSlipstreamTick {
    uint128 liquidityGross;
    int128 liquidityNet;
    int128 stakedLiquidityNet;
    uint256 feeGrowthOutside0X128;
    uint256 feeGrowthOutside1X128;
    uint256 rewardGrowthOutsideX128;
    int56 tickCumulativeOutside;
    uint160 secondsPerLiquidityOutsideX128;
    uint32 secondsOutside;
    bool initialized;
}
