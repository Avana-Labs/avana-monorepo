// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LensClPosition, LensV3Tick} from "./types/LensClReads.sol";

/// @title ILensV3FeeReads
/// @notice The Uniswap v3 pool and NonfungiblePositionManager views the Lens's fee reader decodes (same ABI as
/// v3-core 5ea68a7 and v3-periphery 24ccf01): the 7-field `slot0`, the 8-field `ticks`, the fee growth globals and the
/// 12-field `positions` with `uint24 fee` in field 5.
/// @custom:spec REQ-LENS-050
interface ILensV3FeeReads {
    /// @notice Pool price state; the Lens reads the current tick (field 2).
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);

    /// @notice Fee growth per unit of liquidity over the pool's life, token0, Q128.128.
    function feeGrowthGlobal0X128() external view returns (uint256);

    /// @notice Fee growth per unit of liquidity over the pool's life, token1, Q128.128.
    function feeGrowthGlobal1X128() external view returns (uint256);

    /// @notice A tick's state; the Lens reads `feeGrowthOutside0X128` and `feeGrowthOutside1X128` (fields 3 and 4).
    function ticks(
        int24 tick
    ) external view returns (LensV3Tick memory info);

    /// @notice A position of the position manager; `poolParam` is its `uint24 fee`.
    function positions(
        uint256 tokenId
    ) external view returns (LensClPosition memory position);
}
