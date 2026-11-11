// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title IUniswapV3SwapCallback
/// @notice The callback a Uniswap v3 pool calls on `msg.sender` of `swap`, copied from
/// `contracts/interfaces/callback/IUniswapV3SwapCallback.sol` of Uniswap/v3-core at commit
/// 5ea68a77cb541c6b3812df783be71ba8c081e25f, with an identical selector.
/// @dev Called by: the fixed Uniswap v3 pool of a `DexPath` swap route, which implements this interface.
interface IUniswapV3SwapCallback {
    /// @notice Called on `msg.sender` after a swap; the implementation pays the pool the positive delta owed. Source:
    /// `contracts/interfaces/callback/IUniswapV3SwapCallback.sol` (v3-core 5ea68a7).
    /// @dev Called by: a Uniswap v3 pool during `swap` from a `DexPath` swap route.
    /// @param amount0Delta The amount of token0 sent (negative) or owed (positive) by the pool at the end of the swap.
    /// @param amount1Delta The amount of token1 sent (negative) or owed (positive) by the pool at the end of the swap.
    /// @param data Data passed through by the caller of `swap`.
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}
