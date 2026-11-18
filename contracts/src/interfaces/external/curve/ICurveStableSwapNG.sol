// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICurveStableSwapNG
/// @notice The exchange function and coin getter of a Curve StableSwap-NG plain pool.
/// @dev Avana's declaration of the stableswap-ng ABI (3332cd4), in the overload without `_receiver`.
interface ICurveStableSwapNG {
    /// @notice Exchanges `_dx` of coin `i` for at least `_min_dy` of coin `j`, sent to `msg.sender`.
    /// @param i Index in `coins` of the input coin.
    /// @param j Index in `coins` of the output coin.
    /// @param _min_dy Lowest acceptable amount of coin `j` (swap routes pass 0).
    /// @return Amount of coin `j` sent to `msg.sender`.
    function exchange(
        int128 i,
        int128 j,
        uint256 _dx,
        uint256 _min_dy
    ) external returns (uint256);

    /// @notice Returns the coin at index `i`.
    function coins(
        uint256 i
    ) external view returns (address);
}
