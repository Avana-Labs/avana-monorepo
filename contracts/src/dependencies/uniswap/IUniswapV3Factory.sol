// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title IUniswapV3Factory
/// @notice Subset of the Uniswap v3 factory that Avana calls.
/// @dev Copied from Uniswap/v3-core `IUniswapV3Factory.sol` (5ea68a7), identical selectors.
interface IUniswapV3Factory {
    /// @notice Returns the pool address for a pair of tokens and a fee, or address 0 if it does not exist; `tokenA` and
    /// `tokenB` may be passed in either order.
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address pool);
}
