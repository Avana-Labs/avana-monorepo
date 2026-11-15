// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV4PoolKey} from "../../interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";

/// @title ILensV4FeeReads
/// @notice The Uniswap v4 PoolManager and PositionManager views the Lens's fee reader calls (same ABI as v4-core
/// v4.0.0 and v4-periphery 1.0.1): the PoolManager's raw storage reads, through which the reader takes the pool's tick,
/// fee growth globals, the range's ticks and the position's liquidity and last fee growth (`StateLibrary` layout), and
/// the PositionManager's pool key and packed position info of a token ID.
/// @custom:spec REQ-LENS-050, REQ-AMM-V4-010
interface ILensV4FeeReads {
    /// @notice The word at a PoolManager storage slot.
    function extsload(
        bytes32 slot
    ) external view returns (bytes32 value);

    /// @notice `nSlots` consecutive PoolManager storage words from `startSlot`.
    function extsload(
        bytes32 startSlot,
        uint256 nSlots
    ) external view returns (bytes32[] memory values);

    /// @notice The pool key and packed position info of a PositionManager token ID.
    function getPoolAndPositionInfo(
        uint256 tokenId
    ) external view returns (UniswapV4PoolKey memory poolKey, uint256 info);
}
