// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountRiskView, PledgePreviewView, WithdrawPreview} from "./types/LensTypes.sol";

/// @title ILensPositions
/// @notice Account risk and the pledge and withdrawal previews of the Lens.
interface ILensPositions {
    /// @notice Returns the account's liquidation price and its borrow rates including its risk premium.
    function getAccountRisk(
        address wallet,
        uint256 marketId
    ) external view returns (AccountRiskView memory risk);

    /// @notice Returns `RiskModule.previewPledge` with the block it was read at.
    function previewPledge(
        address depositor,
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (PledgePreviewView memory pledge);

    /// @notice Returns the health factor after withdrawing a record or `units` of it, and whether it would pass.
    /// @param units Units to withdraw; 0 for the whole record.
    function previewWithdraw(
        address wallet,
        uint256 marketId,
        bytes32 positionKey,
        uint256 units
    ) external view returns (WithdrawPreview memory withdrawal);
}
