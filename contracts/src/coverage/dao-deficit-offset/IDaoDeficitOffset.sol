// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IDaoDeficitOffset
/// @notice DAO-funded First-Loss Reserve that pays only once the Avana Umbrella in front is empty or inactive.
interface IDaoDeficitOffset {
    /// @notice `coverDeficit` ran while the Avana Umbrella in front is active on the Hub and still holds funds.
    error FirstLossLayerNotExhausted(address firstLossLayer, uint256 balance);

    /// @notice The constructor's first-loss layer is not a First-Loss Reserve of the same Hub, asset and asset ID.
    error FirstLossLayerMismatch(address firstLossLayer);

    /// @notice The Avana Umbrella this offset stands behind, fixed at deployment.
    function FIRST_LOSS_LAYER() external view returns (address layer);
}
