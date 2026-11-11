// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICurveStableSwapNGFactory
/// @notice The pool-index lookup of the Curve StableSwap-NG factory, which records every pool it deployed. The
/// declaration is the ABI of `get_coin_indices` in `contracts/main/CurveStableSwapFactoryNG.vy` of curvefi/stableswap-ng
/// at commit 3332cd44656ec64b3c048885e1dd71955254b262. The upstream source grants no license; Avana wrote this Solidity
/// declaration of the ABI.
/// @dev Called by: swap routes of kind `DexPath` and `WrapperThenDex`, in the constructor, to check that each Curve hop's
/// pool was deployed by the chain's pinned factory and that its indices match the hop's input and output.
interface ICurveStableSwapNGFactory {
    /// @notice Returns the indices of `_from` and `_to` in `_pool` and whether either is an underlying coin of a
    /// metapool; reverts for a pool the factory did not deploy or coins the pool does not hold. Source:
    /// `contracts/main/CurveStableSwapFactoryNG.vy` (stableswap-ng 3332cd4).
    /// @param _pool The pool.
    /// @param _from The input coin.
    /// @param _to The output coin.
    /// @return i Index of `_from`.
    /// @return j Index of `_to`.
    /// @return isUnderlying True when a coin is an underlying coin of a metapool.
    function get_coin_indices(
        address _pool,
        address _from,
        address _to
    ) external view returns (int128 i, int128 j, bool isUnderlying);
}
