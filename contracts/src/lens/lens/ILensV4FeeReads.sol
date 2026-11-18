// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV4PoolKey} from "../../interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";

/// @title ILensV4FeeReads
/// @notice Uniswap v4 PoolManager storage reads and PositionManager position info used by the Lens fee reader.
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
