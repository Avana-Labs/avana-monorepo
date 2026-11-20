// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title IUniswapV2Positions
/// @notice ERC-721 wrapper of Uniswap v2 LP tokens: each NFT holds an amount of one factory pair's LP token, so a v2
/// position moves through the LPVault like a concentrated-liquidity NFT. Anyone may add LP to a position; only its
/// owner or an approved address takes LP out.
interface IUniswapV2Positions is IERC721 {
    /// @notice The pair is not the factory's pair of its own tokens.
    error InvalidPair(address pair);

    /// @notice The amount is zero, above the position's LP, or no LP arrived.
    error InvalidAmount(uint256 tokenId, uint256 amount);

    /// @notice No position with this ID was minted.
    error UnknownPosition(uint256 tokenId);

    /// @notice A constructor argument is zero or not a contract.
    error InvalidFactory();

    /// @notice LP was wrapped into a new position.
    event Wrapped(uint256 indexed tokenId, address indexed pair, address indexed to, uint256 lpAmount);

    /// @notice LP was added to a position.
    event Increased(uint256 indexed tokenId, address indexed from, uint256 lpAmount);

    /// @notice LP was taken out of a position.
    event Unwrapped(uint256 indexed tokenId, address indexed to, uint256 lpAmount);

    /// @notice The Uniswap v2 factory whose pairs are accepted.
    function FACTORY() external view returns (address);

    /// @notice Pulls `amount` LP of `pair` from the caller into a new position minted to `to`.
    /// @dev The position holds the LP that arrived (balance difference). Mints with `_mint`, so no receiver hook runs.
    function wrap(
        address pair,
        uint256 amount,
        address to
    ) external returns (uint256 tokenId);

    /// @notice Pulls `amount` LP of the position's pair from the caller into position `tokenId`.
    function increase(
        uint256 tokenId,
        uint256 amount
    ) external returns (uint256 received);

    /// @notice Sends `amount` LP of position `tokenId` to `to`; the caller must own or be approved for the NFT.
    /// @dev The NFT stays, possibly empty.
    function unwrap(
        uint256 tokenId,
        uint256 amount,
        address to
    ) external;

    /// @notice The position's pair (zero when none) and LP amount.
    function positions(
        uint256 tokenId
    ) external view returns (address pair, uint256 lpAmount);
}
