// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IUniswapV2Factory
/// @notice Subset of the Uniswap v2 factory that Avana calls; the selectors are v2-core's.
interface IUniswapV2Factory {
    /// @notice The pair of two tokens, in either order, or address 0 if none exists.
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);

    /// @notice The protocol fee recipient; address 0 while the protocol fee is off.
    function feeTo() external view returns (address);
}
