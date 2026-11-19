// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClMarketConfig} from "../amm/types/AmmTypes.sol";
import {ILegacyLPVault} from "./ILegacyLPVault.sol";

/// @title IClIntegration
/// @notice Shared extension of the concentrated-liquidity LPVaults: NFT positions, exact tick ranges and the v3
/// liquidity math.
/// @dev Uncollected fees never enter a position's value.
interface IClIntegration is ILegacyLPVault {
    /// @notice Returns the market's unit exponent `k`: one vault-token unit is `10^k` units of position liquidity.
    /// @dev Fixed for every market of a pool by the pool's first binding.
    /// @return k The unit exponent, at most 18.
    function unitExponent(
        uint256 marketId
    ) external view returns (uint8 k);

    /// @notice Returns the market's concentrated-liquidity configuration.
    function clMarket(
        uint256 marketId
    ) external view returns (ClMarketConfig memory config);

    /// @notice Returns the oracle sqrt price of a market before and after the clamp to its range.
    function oracleSqrtPrice(
        uint256 marketId,
        uint256[] calldata prices
    ) external view returns (uint160 sqrtOracleX96, uint160 sqrtUsedX96, bool clamped);

    /// @notice Returns the NFT token ID of a position key.
    function tokenIdOf(
        bytes32 positionKey
    ) external pure returns (uint256 tokenId);

    /// @notice Accepts an NFT from a bound position manager's `safeTransferFrom` as stray; records nothing.
    /// @dev Reverts `UnsupportedNft` unless `msg.sender` is a bound position manager.
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4 selector);
}
