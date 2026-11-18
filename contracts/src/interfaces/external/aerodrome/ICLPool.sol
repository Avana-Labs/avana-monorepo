// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title ICLPool
/// @notice Subset of the Aerodrome Slipstream pool that Avana reads.
/// @dev `slot0()` returns six fields (no `feeProtocol`), so a Uniswap v3 decoder mis-decodes it.
interface ICLPool {
    /// @notice Returns the factory that created the pool.
    function factory() external view returns (address);

    /// @notice Returns the first token of the pool.
    function token0() external view returns (address);

    /// @notice Returns the second token of the pool.
    function token1() external view returns (address);

    /// @notice Returns the pool's gauge, or address 0.
    function gauge() external view returns (address);

    /// @notice Returns the NPM bound to the pool.
    function nft() external view returns (address);

    /// @notice Returns the pool's tick spacing.
    function tickSpacing() external view returns (int24);

    /// @notice Returns the maximum liquidity per tick.
    function maxLiquidityPerTick() external view returns (uint128);

    /// @notice Returns the packed pool state (six fields).
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );

    /// @notice Returns the current swap fee in pips.
    function fee() external view returns (uint24);

    /// @notice Returns the in-range liquidity.
    function liquidity() external view returns (uint128);

    /// @notice Returns the in-range liquidity staked in the gauge.
    function stakedLiquidity() external view returns (uint128);

    /// @notice Returns tick cumulatives for each `secondsAgos` entry.
    function observe(
        uint32[] calldata secondsAgos
    ) external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
