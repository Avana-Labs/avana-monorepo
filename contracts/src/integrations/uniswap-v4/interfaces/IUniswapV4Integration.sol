// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV4PoolKey} from "../../../dependencies/uniswap-v4/IUniswapV4PoolManager.sol";
import {ILPVault} from "../../../vault/interfaces/ILPVault.sol";

/// @title IUniswapV4Integration
/// @notice The Uniswap v4 LPVault: custody of PositionManager positions of hookless v4 pools, keyed by
/// `bytes32(tokenId)`; a pool is named by its `PoolId`, whose key must be registered first.
/// @dev A native leg is wrapped by the PositionManager, so the market's token0 is the wrapped native token.
interface IUniswapV4Integration is ILPVault {
    /// @notice The pool has a hook, or is not initialized.
    error UnsupportedPool(bytes32 poolId);

    /// @notice A pool key was registered under its `PoolId`.
    event PoolRegistered(bytes32 indexed poolId, address currency0, address currency1, uint24 fee, int24 tickSpacing);

    /// @notice Registers a hookless, initialized pool's key so a market can be listed on its `PoolId`.
    /// @dev Permissionless and idempotent: the `PoolId` is the key's hash. Reverts `UnsupportedPool`.
    /// @return poolId `keccak256(abi.encode(key))`.
    function registerPool(
        UniswapV4PoolKey calldata key
    ) external returns (bytes32 poolId);

    /// @notice Returns a registered pool key; `tickSpacing == 0` when none.
    function poolKey(
        bytes32 poolId
    ) external view returns (UniswapV4PoolKey memory key);

    /// @notice Returns the PoolManager.
    function POOL_MANAGER() external view returns (address poolManager);

    /// @notice Returns the PositionManager whose positions this LPVault holds.
    function POSITION_MANAGER() external view returns (address positionManager);
}
