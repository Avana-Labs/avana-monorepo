// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title IUniswapV3Factory
/// @notice Subset of the Uniswap v3 factory interface that Avana contracts call on the canonical factory, copied from
/// `contracts/interfaces/IUniswapV3Factory.sol` of Uniswap/v3-core at commit
/// 5ea68a77cb541c6b3812df783be71ba8c081e25f, with identical selectors.
/// @dev Called by: Uniswap v3 LPVault (`bindMarket`, `receivePosition`).
interface IUniswapV3Factory {
    /// @notice Returns the pool address for a pair of tokens and a fee, or address 0 if it does not exist; `tokenA`
    /// and `tokenB` may be passed in either order. Source: `contracts/interfaces/IUniswapV3Factory.sol`
    /// (v3-core 5ea68a7).
    /// @dev Called by: Uniswap v3 LPVault (`bindMarket`, `receivePosition`).
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address pool);
}
