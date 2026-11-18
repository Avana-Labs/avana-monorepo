// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaFirstLossReserve} from "../first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserve} from "../first-loss-reserve/IAvanaFirstLossReserve.sol";
import {IDaoDeficitOffset} from "./IDaoDeficitOffset.sol";

/// @title DaoDeficitOffset
/// @notice DAO-funded second loss layer for one `(HUB, ASSET)`, behind the Avana Umbrella `FIRST_LOSS_LAYER`.
contract DaoDeficitOffset is AvanaFirstLossReserve, IDaoDeficitOffset {
    IAvanaFirstLossReserve internal immutable _FIRST_LOSS_LAYER;

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
    function FIRST_LOSS_LAYER() external view override returns (address layer) {
        layer = address(_FIRST_LOSS_LAYER);
    }

    /// @dev A deactivated Umbrella cannot call `eliminateDeficit`, so the offset may then pay while it holds funds.
    function _beforeCover() internal view override {
        address layer = address(_FIRST_LOSS_LAYER);
        if (!_HUB.getSpokeConfig(_ASSET_ID, layer).active) return;
        uint256 balance = _FIRST_LOSS_LAYER.fundedBalance();
        if (balance != 0) revert FirstLossLayerNotExhausted(layer, balance);
    }
}
