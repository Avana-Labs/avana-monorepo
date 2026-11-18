// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IClPositionManager
/// @notice The custody calls the concentrated-liquidity LPVaults make on a Uniswap v3 or Slipstream NFT position
/// manager.
interface IClPositionManager {
    /// @notice Parameters of `decreaseLiquidity`.
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters of `collect`.
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Owner of an NFT; reverts for a token that does not exist.
    function ownerOf(
        uint256 tokenId
    ) external view returns (address owner);

    /// @notice Moves an NFT without calling a receiver hook.
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    /// @notice Removes liquidity and accounts the removed tokens to the position as owed.
    function decreaseLiquidity(
        DecreaseLiquidityParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Pays up to the caps of the tokens owed to the position to `recipient`.
    function collect(
        CollectParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);
}
