// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IUniswapV2Pair
/// @notice Subset of the Uniswap v2 pair that Avana calls; the selectors are v2-core's. The pair is also the ERC-20 of
/// its LP token.
interface IUniswapV2Pair {
    /// @notice The factory that created the pair.
    function factory() external view returns (address);

    /// @notice The lower-sorted token.
    function token0() external view returns (address);

    /// @notice The higher-sorted token.
    function token1() external view returns (address);

    /// @notice The reserves as of the last `mint`, `burn`, `swap` or `sync`, and that block's timestamp.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /// @notice `reserve0 · reserve1` after the last liquidity event while the protocol fee was on, else 0.
    function kLast() external view returns (uint256);

    /// @notice Total supply of the LP token.
    function totalSupply() external view returns (uint256);

    /// @notice Mints LP tokens to `to` for the tokens sent to the pair since the last reserve update.
    function mint(
        address to
    ) external returns (uint256 liquidity);

    /// @notice Burns the LP tokens the pair holds and sends their share of both tokens to `to`.
    function burn(
        address to
    ) external returns (uint256 amount0, uint256 amount1);
}
