// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICurveLegacyPool
/// @notice The exchange function and coin getter of a legacy (pre-NG) Curve StableSwap plain pool.
/// @dev `exchange` declares no return value, so pools that return nothing also decode.
interface ICurveLegacyPool {
    /// @notice Exchanges `dx` of coin `i` for at least `min_dy` of coin `j`, sent to `msg.sender`.
    /// @param i Index in `coins` of the input coin.
    /// @param j Index in `coins` of the output coin.
    /// @param dx Amount of coin `i` sent to the pool, pulled with `transferFrom`.
    /// @param minDy Lowest acceptable amount of coin `j`; swap routes pass 0.
    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 minDy
    ) external;

    /// @notice Returns the coin at index `i`.
    function coins(
        uint256 i
    ) external view returns (address);
}
