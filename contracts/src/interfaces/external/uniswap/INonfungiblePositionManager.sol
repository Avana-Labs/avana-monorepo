// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title INonfungiblePositionManager
/// @notice Subset of the Uniswap v3 NonfungiblePositionManager interface that Avana contracts and test fixtures call
/// on the canonical position manager. Declarations are copied from
/// `contracts/interfaces/INonfungiblePositionManager.sol` of Uniswap/v3-periphery at commit
/// 24ccf014fe7f81d74a14c1689d6fdf123f280e45, with identical selectors, struct layouts and state mutability.
/// @dev The ERC-721 functions (`ownerOf`, `transferFrom`, `approve`) come from OpenZeppelin's `IERC721`, whose
/// selectors equal those the position manager inherits from OpenZeppelin's ERC-721 interfaces.
/// @dev Called by: Uniswap v3 LPVault (`ownerOf`, `positions`, `transferFrom`, `decreaseLiquidity`, `collect`), Lens
/// (`positions`), borrower wallets (`approve`), test fixtures (`mint`, `increaseLiquidity`).
interface INonfungiblePositionManager is IERC721 {
    /// @notice Parameters of `mint`. Source: `contracts/interfaces/INonfungiblePositionManager.sol`
    /// (v3-periphery 24ccf01).
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /// @notice Parameters of `increaseLiquidity`. Source: `contracts/interfaces/INonfungiblePositionManager.sol`
    /// (v3-periphery 24ccf01).
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters of `decreaseLiquidity`. Source: `contracts/interfaces/INonfungiblePositionManager.sol`
    /// (v3-periphery 24ccf01).
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters of `collect`. Source: `contracts/interfaces/INonfungiblePositionManager.sol`
    /// (v3-periphery 24ccf01).
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Returns the Uniswap v3 factory the position manager derives pools from. Source:
    /// `contracts/interfaces/IPeripheryImmutableState.sol` (v3-periphery 24ccf01).
    /// @dev Called by: Uniswap v3 LPVault (constructor check, `REQ-AMM-V3-001`).
    function factory() external view returns (address);

    /// @notice Returns the position data of a token ID; the call reverts if the token ID is not valid. Source:
    /// `contracts/interfaces/INonfungiblePositionManager.sol` (v3-periphery 24ccf01).
    /// @dev Called by: Uniswap v3 LPVault, Lens.
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
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    /// @notice Creates a new position wrapped in an NFT. Source:
    /// `contracts/interfaces/INonfungiblePositionManager.sol` (v3-periphery 24ccf01).
    /// @dev Called by: test fixtures.
    function mint(
        MintParams calldata params
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Increases the liquidity of a position, with tokens paid by `msg.sender`. Source:
    /// `contracts/interfaces/INonfungiblePositionManager.sol` (v3-periphery 24ccf01).
    /// @dev Called by: test fixtures.
    function increaseLiquidity(
        IncreaseLiquidityParams calldata params
    ) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Decreases the liquidity of a position and accounts the removed tokens to the position. Source:
    /// `contracts/interfaces/INonfungiblePositionManager.sol` (v3-periphery 24ccf01).
    /// @dev Called by: Uniswap v3 LPVault.
    function decreaseLiquidity(
        DecreaseLiquidityParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Collects up to a maximum amount of the tokens owed to a position and sends them to `recipient`. Source:
    /// `contracts/interfaces/INonfungiblePositionManager.sol` (v3-periphery 24ccf01).
    /// @dev Called by: Uniswap v3 LPVault.
    function collect(
        CollectParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);
}
