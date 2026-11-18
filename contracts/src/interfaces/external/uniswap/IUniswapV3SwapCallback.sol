// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title IUniswapV3SwapCallback
/// @notice The callback a Uniswap v3 pool calls on `msg.sender` of `swap`.
/// @dev Copied from Uniswap/v3-core `IUniswapV3SwapCallback.sol` (5ea68a7), identical selector.
interface IUniswapV3SwapCallback {
    /// @notice Called on `msg.sender` after a swap; the implementation pays the pool the positive delta owed.
    /// @param amount0Delta The amount of token0 sent (negative) or owed (positive) by the pool at the end of the swap.
    /// @param amount1Delta The amount of token1 sent (negative) or owed (positive) by the pool at the end of the swap.
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}
