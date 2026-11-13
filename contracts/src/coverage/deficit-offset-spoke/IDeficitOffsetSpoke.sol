// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IDeficitOffsetSpoke
/// @notice The DAO deficit offset of one `(Hub, debt asset)`: the second loss layer, behind that pair's Avana Umbrella
/// (Coverage Spoke). It is a Coverage Spoke in every other respect (same functions, roles, events, withdrawal delay and
/// deficit guard), funded by the Aave DAO treasury through `fund`, and it eliminates a recorded deficit only once the
/// Avana Umbrella it stands behind, `FIRST_LOSS_LAYER()`, has a funded balance of zero or is deactivated on the Hub.
/// @dev Aave V4's `Hub.eliminateDeficit(assetId, amount, spoke)` burns the calling Spoke's own added shares, so each
/// layer is its own Spoke and its own Hub position: whose funds a coverage spends is the instance that calls, and the
/// Hub's `EliminateDeficit` event and the instance's `DeficitCovered` name it. On the offset instance
/// `firstLossReserveMinimum()` holds `daoDeficitOffset[hub, asset]`, the size the Aave DAO sets and funds.
/// @custom:spec REQ-FLR-046, REQ-FLR-047, REQ-FLR-048, REQ-FLR-049, SPEC-FLR-006, INV-100, Q-410
interface IDeficitOffsetSpoke {
    /// @notice `coverDeficit` ran while the Avana Umbrella in front is active on the Hub and still holds funds.
    /// @param firstLossLayer The Avana Umbrella (Coverage Spoke) of the same `(Hub, asset)`.
    /// @param balance Its `fundedBalance()` at the call.
    /// @custom:spec REQ-FLR-048, REQ-FLR-050
    error FirstLossLayerNotExhausted(address firstLossLayer, uint256 balance);

    /// @notice The constructor's first-loss layer is not a Coverage Spoke of the same Hub, asset and asset ID.
    /// @param firstLossLayer The rejected address.
    /// @custom:spec REQ-FLR-047
    error FirstLossLayerMismatch(address firstLossLayer);

    /// @notice The Avana Umbrella (Coverage Spoke) this offset stands behind, fixed at deployment.
    /// @return layer Coverage Spoke address on the same `(HUB(), ASSET_ID())`.
    /// @custom:spec REQ-FLR-046, REQ-FLR-047
    function FIRST_LOSS_LAYER() external view returns (address layer);
}
