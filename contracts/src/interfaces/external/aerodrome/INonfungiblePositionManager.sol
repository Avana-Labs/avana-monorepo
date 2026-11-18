// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title INonfungiblePositionManager
/// @notice Subset of the Aerodrome Slipstream NonfungiblePositionManager that Avana calls.
/// @dev `positions` returns `int24 tickSpacing` where Uniswap v3 returns `uint24 fee`.
interface INonfungiblePositionManager {
    /// @notice Parameters of `decreaseLiquidity`.
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters of `collect`.
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Returns the pool factory of the position manager.
    function factory() external view returns (address);

    /// @notice Returns the position of `tokenId`.
    function positions(
        uint256 tokenId
    )
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    /// @notice Removes liquidity; reverts below the minimums.
    function decreaseLiquidity(
        DecreaseLiquidityParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Collects up to the maximums of owed tokens to `recipient`.
    function collect(
        CollectParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Returns the owner of `tokenId`.
    function ownerOf(
        uint256 tokenId
    ) external view returns (address owner);

    /// @notice Transfers `tokenId` without a receiver callback.
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;
}
