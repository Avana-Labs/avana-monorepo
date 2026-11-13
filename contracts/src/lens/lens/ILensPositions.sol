// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountRiskView} from "./types/AccountRiskView.sol";
import {PledgePreviewView} from "./types/PledgePreviewView.sol";
import {WithdrawPreview} from "./types/WithdrawPreview.sol";

/// @title ILensPositions
/// @notice Account risk and the pledge and withdrawal previews of the Lens.
interface ILensPositions {
    /// @notice Returns the account's liquidation price and its borrow rates including its risk premium.
    /// @param wallet The wallet.
    /// @param marketId The account's market.
    /// @return risk The view.
    /// @custom:spec REQ-LENS-047
    function getAccountRisk(
        address wallet,
        uint256 marketId
    ) external view returns (AccountRiskView memory risk);

    /// @notice Returns `RiskModule.previewPledge` with the block it was read at.
    /// @param depositor Current owner of the position.
    /// @param marketId The market.
    /// @param positionKey The position.
    /// @return pledge The preview.
    /// @custom:spec REQ-LENS-048
    function previewPledge(
        address depositor,
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (PledgePreviewView memory pledge);

    /// @notice Returns the health factor after withdrawing a record (`units = 0`) or `units` of it, and whether the
    /// withdrawal would pass.
    /// @param wallet The wallet.
    /// @param marketId The account's market.
    /// @param positionKey The record's position.
    /// @param units Units to withdraw; 0 for the whole record.
    /// @return withdrawal The preview.
    /// @custom:spec REQ-LENS-049
    function previewWithdraw(
        address wallet,
        uint256 marketId,
        bytes32 positionKey,
        uint256 units
    ) external view returns (WithdrawPreview memory withdrawal);
}
