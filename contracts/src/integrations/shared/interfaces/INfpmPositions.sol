// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title INfpmPositions
/// @notice The `positions` read shared by the Uniswap v3 and Slipstream position managers, as one static struct (the
/// same ABI as their 12 return values).
interface INfpmPositions {
    /// @notice A position manager's position.
    /// @param feeOrTickSpacing Uniswap v3: the fee tier. Slipstream: the tick spacing (always positive).
    struct NfpmPositionData {
        uint96 nonce;
        address operator;
        address token0;
        address token1;
        uint24 feeOrTickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @notice Returns the position of a token ID; reverts for an unknown one.
    function positions(
        uint256 tokenId
    ) external view returns (NfpmPositionData memory position);
}
