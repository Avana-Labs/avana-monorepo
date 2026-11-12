// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICurveLegacyPool
/// @notice The exchange function and coin getter of a legacy (pre-NG) Curve StableSwap plain pool that Avana swap routes
/// call on a fixed, pinned pool. The declarations are the ABI of `exchange` and `coins` of the Ethereum 3pool
/// (`StableSwap3Pool.vy` in curvefi/curve-contract, deployed at `0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7`):
/// `exchange(i: int128, j: int128, dx: uint256, min_dy: uint256)` with the output sent to `msg.sender`, and
/// `coins(arg0: uint256) -> address`. The upstream source grants no license; Avana wrote this Solidity declaration of
/// the ABI.
/// @dev Called by: swap routes of kind `DexPath` and `WrapperThenDex`. `exchange` is declared with no return value: the
/// 3pool returns nothing and later legacy pools return the amount, and a call declared without a return value accepts
/// both; routes measure the output as their own balance rise, never from a return value. The selector equals the
/// StableSwap-NG `exchange(int128,int128,uint256,uint256)`. The oldest pools, whose getter is `coins(int128)`, answer no
/// `coins(uint256)` read and are refused at construction.
interface ICurveLegacyPool {
    /// @notice Exchanges `dx` of coin `i` for at least `min_dy` of coin `j`, sent to `msg.sender`.
    /// @dev Called by: swap routes of kind `DexPath` and `WrapperThenDex`, with `min_dy = 0`.
    /// @param i Index in `coins` of the input coin.
    /// @param j Index in `coins` of the output coin.
    /// @param dx Amount of coin `i` sent to the pool, pulled with `transferFrom`.
    /// @param minDy Lowest acceptable amount of coin `j` (`min_dy`); swap routes pass 0 and enforce the per-leg oracle
    /// minimum on LPVaultSwap's balance delta of the debt asset.
    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 minDy
    ) external;

    /// @notice Returns the coin at index `i`.
    /// @dev Called by: swap routes of kind `DexPath` and `WrapperThenDex`, in the constructor, to check each legacy
    /// Curve hop's indices against its input and output tokens.
    /// @param i Coin index.
    /// @return The coin's token address.
    function coins(
        uint256 i
    ) external view returns (address);
}
