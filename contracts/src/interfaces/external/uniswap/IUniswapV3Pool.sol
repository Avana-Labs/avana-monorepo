// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title IUniswapV3Pool
/// @notice Subset of the Uniswap v3 pool that Avana calls on a market pool or a fixed route pool.
/// @dev Copied from Uniswap/v3-core pool interfaces (5ea68a7), identical selectors.
interface IUniswapV3Pool {
    /// @notice Returns the factory that deployed the pool.
    function factory() external view returns (address);

    /// @notice Returns the first of the two tokens of the pool, sorted by address.
    function token0() external view returns (address);

    /// @notice Returns the second of the two tokens of the pool, sorted by address.
    function token1() external view returns (address);

    /// @notice Returns the pool's fee in hundredths of a bip.
    function fee() external view returns (uint24);

    /// @notice Returns the pool tick spacing.
    function tickSpacing() external view returns (int24);

    /// @notice Returns the pool's packed slot 0; `unlocked` is false while the pool is inside a call.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    /// @notice Fee growth per unit of liquidity over the pool's life, token0, Q128.128.
    function feeGrowthGlobal0X128() external view returns (uint256);

    /// @notice Fee growth per unit of liquidity over the pool's life, token1, Q128.128.
    function feeGrowthGlobal1X128() external view returns (uint256);

    /// @notice Returns the state of a tick.
    function ticks(
        int24 tick
    )
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    /// @notice Returns the currently in-range liquidity available to the pool.
    function liquidity() external view returns (uint128);

    /// @notice Returns the cumulative tick and seconds-per-liquidity values as of each `secondsAgos` before now; the
    /// call reverts if an observation older than the oldest stored one is requested.
    function observe(
        uint32[] calldata secondsAgos
    ) external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice Swaps token0 for token1, or token1 for token0, paying through `uniswapV3SwapCallback` on the caller.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    /// @notice Increases the maximum number of price and liquidity observations the pool will store.
    function increaseObservationCardinalityNext(
        uint16 observationCardinalityNext
    ) external;
}
