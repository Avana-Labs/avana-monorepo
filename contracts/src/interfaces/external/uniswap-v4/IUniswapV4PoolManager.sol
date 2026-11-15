// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A Uniswap v4 pool's key, hashed to its `PoolId` as `keccak256(abi.encode(key))`. Copied from
/// `src/types/PoolKey.sol` of Uniswap/v4-core at v4.0.0 (e50237c) with `Currency` and `IHooks` as plain addresses
/// (same ABI); `currency0 == address(0)` is native ETH.
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
/// @notice Subset of the Uniswap v4 PoolManager that Avana contracts call: the raw storage and transient-storage reads
/// (`IExtsload`, `IExttload` of Uniswap/v4-core at v4.0.0, e50237c), with identical selectors.
/// @dev Called by: Uniswap v4 LPVault, v4 LPOracle module, Lens. Every read Avana makes goes through these three
/// functions with the slot layout of v4-core's `StateLibrary` and `Lock`.
interface IUniswapV4PoolManager {
    /// @notice Returns the word at a storage slot. Source: `src/interfaces/IExtsload.sol` (v4-core e50237c).
    function extsload(
        bytes32 slot
    ) external view returns (bytes32 value);

    /// @notice Returns `nSlots` consecutive words from `startSlot`. Source: `src/interfaces/IExtsload.sol`.
    function extsload(
        bytes32 startSlot,
        uint256 nSlots
    ) external view returns (bytes32[] memory values);

    /// @notice Returns the word at a transient-storage slot. Source: `src/interfaces/IExttload.sol`.
    function exttload(
        bytes32 slot
    ) external view returns (bytes32 value);
}
