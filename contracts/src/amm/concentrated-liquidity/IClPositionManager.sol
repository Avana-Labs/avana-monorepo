// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IClPositionManager
/// @notice The custody calls every concentrated-liquidity LPVault makes on its AMM protocol's NFT position manager:
/// ownership, transfer, liquidity removal and owed-token collection.
/// @dev These selectors, struct layouts and return values are identical on the Uniswap v3
/// NonfungiblePositionManager (v3-periphery 24ccf01) and the Aerodrome Slipstream NonfungiblePositionManager, so the
/// shared custody code calls them through this one interface. `positions` differs between the two (`uint24 fee`
/// against `int24 tickSpacing`) and is decoded by each integration with its own external interface.
/// @custom:spec REQ-AMM-V3-004, REQ-VAULT-004, REQ-VAULT-097, Q-371
interface IClPositionManager {
    /// @notice Parameters of `decreaseLiquidity`.
    struct DecreaseLiquidityParams {
        // NFT token ID.
        uint256 tokenId;
        // Liquidity to remove.
        uint128 liquidity;
        // Minimum token0 the removal must account.
        uint256 amount0Min;
        // Minimum token1 the removal must account.
        uint256 amount1Min;
        // Deadline, seconds.
        uint256 deadline;
    }

    /// @notice Parameters of `collect`.
    struct CollectParams {
        // NFT token ID.
        uint256 tokenId;
        // Receiver of the collected tokens.
        address recipient;
        // Cap on token0 collected.
        uint128 amount0Max;
        // Cap on token1 collected.
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
