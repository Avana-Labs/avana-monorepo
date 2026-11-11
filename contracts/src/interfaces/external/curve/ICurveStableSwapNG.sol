// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICurveStableSwapNG
/// @notice The exchange function and coin getter of a Curve StableSwap-NG plain pool that Avana swap routes call on a
/// fixed pool. The declarations are the ABI of `exchange` and `coins` in `contracts/main/CurveStableSwapNG.vy` of curvefi/stableswap-ng at
/// commit 3332cd44656ec64b3c048885e1dd71955254b262, in the overload without `_receiver` (`exchange(i, j, _dx,
/// _min_dy)`, output sent to `msg.sender`). The upstream source grants no license; Avana wrote this Solidity
/// declaration of the ABI.
/// @dev Called by: swap routes of kind `DexPath`.
interface ICurveStableSwapNG {
    /// @notice Exchanges `_dx` of coin `i` for at least `_min_dy` of coin `j`, sent to `msg.sender`. Source:
    /// `contracts/main/CurveStableSwapNG.vy` (stableswap-ng 3332cd4).
    /// @dev Called by: swap routes of kind `DexPath`.
    /// @param i Index in `coins` of the input coin.
    /// @param j Index in `coins` of the output coin.
    /// @param _dx Amount of coin `i` sent to the pool.
    /// @param _min_dy Lowest acceptable amount of coin `j`; swap routes pass 0 and enforce the per-leg oracle minimum on
    /// LPVaultSwap's balance delta of the debt asset.
    /// @return Amount of coin `j` sent to `msg.sender`.
    function exchange(
        int128 i,
        int128 j,
        uint256 _dx,
        uint256 _min_dy
    ) external returns (uint256);

    /// @notice Returns the coin at index `i`. Source: `contracts/main/CurveStableSwapNG.vy` (stableswap-ng 3332cd4).
    /// @dev Called by: swap routes of kind `DexPath` and `WrapperThenDex`, in the constructor, to check each Curve hop's
    /// indices against its input and output tokens.
    /// @param i Coin index.
    /// @return The coin's token address.
    function coins(
        uint256 i
    ) external view returns (address);
}
