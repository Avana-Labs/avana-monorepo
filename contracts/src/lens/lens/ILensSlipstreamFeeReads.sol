// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LensClPosition, LensSlipstreamTick} from "./types/LensTypes.sol";

/// @title ILensSlipstreamFeeReads
/// @notice Aerodrome Slipstream pool and position manager views used by the Lens fee reader.
interface ILensSlipstreamFeeReads {
    /// @notice Pool price state; the Lens reads the current tick (field 2).
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool);

    /// @notice Fee growth per unit of unstaked liquidity over the pool's life, token0, Q128.128.
    function feeGrowthGlobal0X128() external view returns (uint256);

    /// @notice Fee growth per unit of unstaked liquidity over the pool's life, token1, Q128.128.
    function feeGrowthGlobal1X128() external view returns (uint256);

    /// @notice A tick's state; the Lens reads `feeGrowthOutside0X128` and `feeGrowthOutside1X128` (fields 4 and 5).
    function ticks(
        int24 tick
    ) external view returns (LensSlipstreamTick memory info);

    /// @notice A position of the position manager; `poolParam` is its `int24 tickSpacing`.
    function positions(
        uint256 tokenId
    ) external view returns (LensClPosition memory position);
}
