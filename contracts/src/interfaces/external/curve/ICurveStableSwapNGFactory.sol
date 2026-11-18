// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICurveStableSwapNGFactory
/// @notice The pool-index lookup of the Curve StableSwap-NG factory, which records every pool it deployed.
/// @dev Avana's declaration of the curvefi/stableswap-ng ABI (3332cd4; upstream grants no license).
interface ICurveStableSwapNGFactory {
    /// @notice Returns the indices of `_from` and `_to` in `_pool` and whether either is an underlying coin of a
    /// metapool; reverts for a pool the factory did not deploy or coins the pool does not hold.
    function get_coin_indices(
        address _pool,
        address _from,
        address _to
    ) external view returns (int128 i, int128 j, bool isUnderlying);
}
