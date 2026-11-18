// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV4PoolKey} from "../../interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {IClIntegration} from "../IClIntegration.sol";

/// @title IUniswapV4Integration
/// @notice The Uniswap v4 LPVault: custody of PositionManager positions of hookless v4 pools in exact-range markets.
/// @dev The consistency read and the depth come from a reference Uniswap v3 pool of the same two tokens.
interface IUniswapV4Integration is IClIntegration {
    /// @notice A v4 market's pool key and reference pool, written at `bindMarket`.
    struct V4Market {
        UniswapV4PoolKey key;
        address referencePool;
    }

    /// @notice The position has a subscriber.
    error SubscribedPosition();

    /// @notice The pool's hook is not allowed.
    error HookNotAllowed(address hooks);

    /// @notice Returns the PoolManager.
    function POOL_MANAGER() external view returns (address poolManager);

    /// @notice Returns the PositionManager whose positions this LPVault custodies.
    function POSITION_MANAGER() external view returns (address positionManager);

    /// @notice Returns the Uniswap v3 factory reference pools are checked against.
    function REFERENCE_FACTORY() external view returns (address factory);

    /// @notice Returns the chain's minimum block interval in seconds, used for the observation check.
    function BLOCK_TIME() external view returns (uint256 blockTime);

    /// @notice Hook permission bits a pool's hook must clear.
    function HOOK_MASK() external view returns (uint160 mask);

    /// @notice Returns a bound market's pool key and reference pool.
    function v4Market(
        uint256 marketId
    ) external view returns (V4Market memory market);
}
