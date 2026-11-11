// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title INonfungiblePositionManager
/// @notice Subset of the Aerodrome Slipstream NonfungiblePositionManager interface that Avana calls, copied from
/// `contracts/periphery/interfaces/INonfungiblePositionManager.sol` of aerodrome-finance/slipstream `main` (read 2026-11-10), with identical selectors;
/// `ownerOf` and `transferFrom` come from the inherited ERC-721 interface.
/// @dev Called by: the Slipstream LPVault. `positions` returns `int24 tickSpacing` where Uniswap v3 returns
/// `uint24 fee`; the decoders are not interchangeable.
interface INonfungiblePositionManager {
    /// @notice Parameters of `decreaseLiquidity`. Source: `INonfungiblePositionManager.sol`.
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters of `collect`. Source: `INonfungiblePositionManager.sol`.
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Returns the pool factory of the position manager. Source: `IPeripheryImmutableState.sol`.
    /// @dev Called by: Slipstream LPVault constructor, to require each generation's manager to name its paired factory.
    function factory() external view returns (address);

    /// @notice Returns the position of `tokenId`. Source: `INonfungiblePositionManager.sol`.
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

    /// @notice Removes liquidity; reverts below the minimums. Source: `INonfungiblePositionManager.sol`.
    function decreaseLiquidity(
        DecreaseLiquidityParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Collects up to the maximums of owed tokens to `recipient`. Source: `INonfungiblePositionManager.sol`.
    function collect(
        CollectParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Returns the owner of `tokenId`. Source: ERC-721.
    function ownerOf(
        uint256 tokenId
    ) external view returns (address owner);

    /// @notice Transfers `tokenId` without a receiver callback. Source: ERC-721.
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;
}
