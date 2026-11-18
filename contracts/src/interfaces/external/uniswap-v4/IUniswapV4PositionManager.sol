// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UniswapV4PoolKey} from "./IUniswapV4PoolManager.sol";

/// @title IUniswapV4PositionManager
/// @notice Subset of the Uniswap v4 PositionManager that Avana calls.
/// @dev Copied from Uniswap/v4-periphery 1.0.1, with `PositionInfo` as its underlying `uint256` (same ABI).
interface IUniswapV4PositionManager {
    /// @notice Runs a batch of actions inside one `PoolManager.unlock`; `unlockData = abi.encode(bytes actions,
    /// bytes[] params)`. Reverts after `deadline`.
    function modifyLiquidities(
        bytes calldata unlockData,
        uint256 deadline
    ) external payable;

    /// @notice The pool key and packed position info of a token ID (zero for a token that was never minted).
    function getPoolAndPositionInfo(
        uint256 tokenId
    ) external view returns (UniswapV4PoolKey memory poolKey, uint256 info);

    /// @notice Owner of an NFT; reverts for a token that does not exist.
    function ownerOf(
        uint256 tokenId
    ) external view returns (address owner);

    /// @notice Moves an NFT without a receiver hook; reverts while the PoolManager is unlocked and drops any
    /// subscriber.
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    /// @notice The PoolManager the position manager settles against.
    function poolManager() external view returns (address);

    /// @notice The wrapped native token of the `WRAP` and `UNWRAP` actions.
    function WETH9() external view returns (address);
}
