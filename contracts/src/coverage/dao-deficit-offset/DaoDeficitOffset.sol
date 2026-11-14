// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaFirstLossReserve} from "../first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserve} from "../first-loss-reserve/IAvanaFirstLossReserve.sol";
import {IDaoDeficitOffset} from "./IDaoDeficitOffset.sol";

/// @title DaoDeficitOffset
/// @notice The DAO deficit offset of one `(HUB, ASSET)`: a First-Loss Reserve funded by the Aave DAO treasury that stands
/// behind that pair's Avana Umbrella (`FIRST_LOSS_LAYER`) and eliminates a recorded deficit only once the Avana Umbrella's
/// funded balance is zero or the Aave DAO has deactivated it on the Hub (so it cannot pay); Avana's first-loss capital
/// is spent before the DAO's whenever the Avana Umbrella can pay.
/// @dev Inherits every First-Loss Reserve rule unchanged (immutable, AccessManager-only authority, `fund` by anyone,
/// `coverDeficit` bounded by `SPEC-FLR-001`, 14-day DAO withdrawals behind the deficit guard) and adds one check in
/// `coverDeficit` through `_beforeCover`: views of the layer's Hub `active` flag and of
/// `FIRST_LOSS_LAYER.fundedBalance()`. Each layer is its own Hub position, so the Hub itself keeps whose funds were spent.
/// @custom:spec REQ-FLR-046, REQ-FLR-047, REQ-FLR-048, REQ-FLR-049, SPEC-FLR-006, INV-100, Q-410
contract DaoDeficitOffset is AvanaFirstLossReserve, IDaoDeficitOffset {
    /// @dev The Avana Umbrella (First-Loss Reserve) of the same `(HUB, ASSET_ID)`.
    IAvanaFirstLossReserve internal immutable _FIRST_LOSS_LAYER;

    /// @notice Fixes the instance as a First-Loss Reserve of `(hub, asset, assetId)` behind `firstLossLayer`.
    /// @dev Reverts as the First-Loss Reserve constructor does, then `ZeroAddress` for a zero `firstLossLayer` and
    /// `FirstLossLayerMismatch` unless its `HUB()`, `ASSET()` and `ASSET_ID()` equal this instance's.
    /// @param hub The funding Hub.
    /// @param asset The covered debt asset.
    /// @param assetId `asset`'s asset ID on `hub`.
    /// @param authority The Aave DAO's AccessManager.
    /// @param reserveWithdrawalDelay Seconds; must be 1,209,600.
    /// @param firstLossLayer The Avana Umbrella of `(hub, asset)`.
    /// @custom:spec REQ-FLR-047, REQ-FLR-008
    constructor(
        address hub,
        address asset,
        uint256 assetId,
        address authority,
        uint256 reserveWithdrawalDelay,
        address firstLossLayer
    ) AvanaFirstLossReserve(hub, asset, assetId, authority, reserveWithdrawalDelay) {
        if (firstLossLayer == address(0)) revert ZeroAddress();
        IAvanaFirstLossReserve layer = IAvanaFirstLossReserve(firstLossLayer);
        if (layer.HUB() != hub || layer.ASSET() != asset || layer.ASSET_ID() != assetId) {
            revert FirstLossLayerMismatch(firstLossLayer);
        }
        _FIRST_LOSS_LAYER = layer;
    }

    /// @inheritdoc IDaoDeficitOffset
    /// @custom:spec REQ-FLR-046, REQ-FLR-047
    function FIRST_LOSS_LAYER() external view override returns (address layer) {
        layer = address(_FIRST_LOSS_LAYER);
    }

    /// @notice Loss order: reverts `FirstLossLayerNotExhausted(layer, balance)` while the Avana Umbrella in front is
    /// active on the Hub and holds a non-zero funded balance. A deactivated Avana Umbrella cannot call
    /// `eliminateDeficit` (`SpokeNotActive`), so the offset may then pay although it still holds funds (`Q-410`).
    /// @dev Views of the Hub's Spoke config and of the immutable first-loss layer, made before this instance's Hub call.
    /// @custom:spec REQ-FLR-048, REQ-FLR-050, SPEC-FLR-006, INV-100, Q-410
    function _beforeCover() internal view override {
        address layer = address(_FIRST_LOSS_LAYER);
        if (!_HUB.getSpokeConfig(_ASSET_ID, layer).active) return;
        uint256 balance = _FIRST_LOSS_LAYER.fundedBalance();
        if (balance != 0) revert FirstLossLayerNotExhausted(layer, balance);
    }
}
