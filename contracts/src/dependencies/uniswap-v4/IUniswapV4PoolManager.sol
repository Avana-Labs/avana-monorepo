// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A Uniswap v4 pool's key (v4-core `PoolKey` with `Currency` and `IHooks` as plain addresses).
struct UniswapV4PoolKey {
    // The lower currency, sorted numerically.
    address currency0;
    // The higher currency, sorted numerically.
    address currency1;
    // The LP fee in hundredths of a bip; the dynamic-fee flag 0x800000 marks a hook-set fee.
    uint24 fee;
    // Ticks a position's bounds must be multiples of.
    int24 tickSpacing;
    // The pool's hook contract; its low 14 address bits are its permission flags.
    address hooks;
}

/// @title IUniswapV4PoolManager
/// @notice Subset of the Uniswap v4 PoolManager that Avana calls: raw storage and transient-storage reads.
/// @dev Copied from Uniswap/v4-core v4.0.0 `IExtsload` and `IExttload`, identical selectors.
interface IUniswapV4PoolManager {
    /// @notice Returns the word at a storage slot.
    function extsload(
        bytes32 slot
    ) external view returns (bytes32 value);

    /// @notice Returns `nSlots` consecutive words from `startSlot`.
    function extsload(
        bytes32 startSlot,
        uint256 nSlots
    ) external view returns (bytes32[] memory values);

    /// @notice Returns the word at a transient-storage slot.
    function exttload(
        bytes32 slot
    ) external view returns (bytes32 value);
}
