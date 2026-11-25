// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "./ILPVault.sol";

/// @title IUniswapV2Integration
/// @notice The Uniswap v2 LPVault: custody of `UniswapV2Positions` NFTs, each holding one pair's LP token, keyed by
/// `bytes32(tokenId)`; a pool is the pair's address as a word. A v2 position is the full range `[MIN_TICK, MAX_TICK]`
/// with liquidity `lpAmount · √(reserve0 · reserve1) / totalSupply`, so it fits only a Full range market listed with
/// tick spacing 1.
interface IUniswapV2Integration is ILPVault {
    /// @notice The `UniswapV2Positions` wrapper.
    function POSITIONS() external view returns (address positions);

    /// @notice The canonical Uniswap v2 factory.
    function FACTORY() external view returns (address factory);

    /// @notice Tick spacing reported for every pair: 1, so the Full range band is `[MIN_TICK, MAX_TICK]`.
    function TICK_SPACING() external view returns (int24);

    /// @notice Liquidity of `lpAmount` LP of `pair` now: `lpAmount · √(reserve0 · reserve1) / supply`, where `supply`
    /// includes the protocol fee the pair would mint at its next `mint` or `burn`. Rounded down.
    function liquidityOf(
        address pair,
        uint256 lpAmount
    ) external view returns (uint128 liquidity);
}
