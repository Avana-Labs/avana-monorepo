// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IUniswapV2Factory} from "../../dependencies/uniswap-v2/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "../../dependencies/uniswap-v2/IUniswapV2Pair.sol";
import {IUniswapV2Positions} from "./interfaces/IUniswapV2Positions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title UniswapV2Positions
/// @notice ERC-721 wrapper of Uniswap v2 LP tokens, the position manager of the Uniswap v2 LPVault (see DESIGN.md).
/// @dev No roles and no upgrade path. Only the factory's own pairs are wrapped, and LP amounts are what arrived.
contract UniswapV2Positions is IUniswapV2Positions, ERC721, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Position {
        address pair;
        uint256 lpAmount;
    }

    address private immutable _FACTORY;
    uint256 private _nextId = 1;
    mapping(uint256 tokenId => Position position) private _positions;

    /// @notice Fixes the factory.
    /// @dev Reverts `InvalidFactory` unless it is a contract.
    constructor(
        address factory
    ) ERC721("Avana Uniswap v2 Position", "AVANA-V2-POS") {
        if (factory == address(0) || factory.code.length == 0) revert InvalidFactory();
        _FACTORY = factory;
    }

    /// @inheritdoc IUniswapV2Positions
    function FACTORY() external view override returns (address) {
        return _FACTORY;
    }

    /// @inheritdoc IUniswapV2Positions
    function wrap(
        address pair,
        uint256 amount,
        address to
    ) external override nonReentrant returns (uint256 tokenId) {
        if (pair.code.length == 0) revert InvalidPair(pair);
        IUniswapV2Pair p = IUniswapV2Pair(pair);
        if (IUniswapV2Factory(_FACTORY).getPair(p.token0(), p.token1()) != pair) revert InvalidPair(pair);
        tokenId = _nextId++;
        uint256 received = _pull(tokenId, pair, amount);
        _positions[tokenId] = Position({pair: pair, lpAmount: received});
        _mint(to, tokenId);
        emit Wrapped(tokenId, pair, to, received);
    }

    /// @inheritdoc IUniswapV2Positions
    function increase(
        uint256 tokenId,
        uint256 amount
    ) external override nonReentrant returns (uint256 received) {
        Position storage p = _positions[tokenId];
        if (p.pair == address(0)) revert UnknownPosition(tokenId);
        received = _pull(tokenId, p.pair, amount);
        p.lpAmount += received;
        emit Increased(tokenId, msg.sender, received);
    }

    /// @inheritdoc IUniswapV2Positions
    function unwrap(
        uint256 tokenId,
        uint256 amount,
        address to
    ) external override nonReentrant {
        _checkAuthorized(_ownerOf(tokenId), msg.sender, tokenId);
        Position storage p = _positions[tokenId];
        if (amount == 0 || amount > p.lpAmount) revert InvalidAmount(tokenId, amount);
        p.lpAmount -= amount;
        emit Unwrapped(tokenId, to, amount);
        IERC20(p.pair).safeTransfer(to, amount);
    }

    /// @inheritdoc IUniswapV2Positions
    function positions(
        uint256 tokenId
    ) external view override returns (address pair, uint256 lpAmount) {
        Position storage p = _positions[tokenId];
        return (p.pair, p.lpAmount);
    }

    /// @dev Pulls `amount` LP from the caller and returns what arrived; reverts `InvalidAmount` when nothing did.
    function _pull(
        uint256 tokenId,
        address pair,
        uint256 amount
    ) private returns (uint256 received) {
        uint256 before = IERC20(pair).balanceOf(address(this));
        IERC20(pair).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(pair).balanceOf(address(this)) - before;
        if (received == 0) revert InvalidAmount(tokenId, amount);
    }
}
