// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV4PoolKey} from "../../interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {IClIntegration} from "../IClIntegration.sol";

/// @title IUniswapV4Integration
/// @notice The Uniswap v4 LPVault: custody of PositionManager positions of hookless v4 pools in exact-range markets,
/// keyed by `PoolId`.
/// @dev `positionKey = bytes32(tokenId)`. A position matches a market only when the PoolKey of
/// `PositionManager.getPoolAndPositionInfo(tokenId)` hashes to the market's `PoolId` and its ticks equal the market's
/// range; its liquidity is read from the PoolManager (salt `bytes32(tokenId)`, owner the PositionManager). A native-ETH
/// `currency0` is carried as `WETH` everywhere in Avana. Each market has a reference pool, the canonical Uniswap v3 pool
/// of its two tokens, whose TWAP is the consistency read and whose harmonic-mean liquidity is the depth
/// (`REQ-AMM-V4-005`, `REQ-AMM-V4-007`, `REQ-AMM-V4-008`).
/// @custom:spec REQ-AMM-V4-001, REQ-AMM-V4-002, REQ-AMM-V4-003, REQ-AMM-V4-004, REQ-AMM-V4-005, REQ-AMM-V4-007, REQ-AMM-V4-008, REQ-AMM-V4-009
interface IUniswapV4Integration is IClIntegration {
    /// @notice A v4 market's pool key and reference pool, written at `bindMarket`.
    struct V4Market {
        // The pool's key; `keccak256(abi.encode(key))` is the market's `PoolId`.
        UniswapV4PoolKey key;
        // The canonical Uniswap v3 pool of the same two tokens.
        address referencePool;
    }

    /// @notice The position has a subscriber (`REQ-AMM-V4-002`).
    error SubscribedPosition();

    /// @notice The pool's hook is not allowed (`REQ-AMM-V4-001`, `REQ-AMM-V4-006`).
    /// @param hooks The pool key's hook address.
    error HookNotAllowed(address hooks);

    /// @notice Returns the PoolManager.
    /// @return poolManager Constructor immutable.
    function POOL_MANAGER() external view returns (address poolManager);

    /// @notice Returns the PositionManager whose positions this LPVault custodies.
    /// @return positionManager Constructor immutable.
    function POSITION_MANAGER() external view returns (address positionManager);

    /// @notice Returns the Uniswap v3 factory reference pools are checked against.
    /// @return factory Constructor immutable.
    function REFERENCE_FACTORY() external view returns (address factory);

    /// @notice Returns the chain's minimum block interval the reference pool's observation check uses.
    /// @return blockTime Constructor immutable, seconds.
    function BLOCK_TIME() external view returns (uint256 blockTime);

    /// @notice Hook permission bits a pool's hook must clear (`REQ-AMM-V4-001`).
    /// @return mask `BEFORE_REMOVE_LIQUIDITY | AFTER_REMOVE_LIQUIDITY | BEFORE_SWAP_RETURNS_DELTA |
    /// AFTER_SWAP_RETURNS_DELTA | AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` = `0x30d`.
    function HOOK_MASK() external view returns (uint160 mask);

    /// @notice Returns a bound market's pool key and reference pool.
    /// @dev Reverts with `MarketBinding` for a market not bound to this integration.
    function v4Market(
        uint256 marketId
    ) external view returns (V4Market memory market);
}
