// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ActionPreview} from "./types/ActionPreview.sol";

/// @title ILensActions
/// @notice An account's health factor and liquidation price before and after one borrow, repay, pledge or withdrawal,
/// computed with Aave's own formulas at the block's served prices.
interface ILensActions {
    /// @notice Returns the account before and after borrowing `amount` of a debt reserve.
    /// @param wallet The wallet.
    /// @param marketId The account's market.
    /// @param debtReserveId Enabled debt reserve of the market's CDP Spoke.
    /// @param amount Debt-asset base units.
    /// @return preview The preview.
    /// @custom:spec REQ-LENS-052
    function previewBorrowAfter(
        address wallet,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 amount
    ) external view returns (ActionPreview memory preview);

    /// @notice Returns the account before and after repaying `amount` of a debt reserve (any amount at or above the
    /// debt repays all of it).
    /// @param wallet The wallet.
    /// @param marketId The account's market.
    /// @param debtReserveId Enabled debt reserve of the market's CDP Spoke.
    /// @param amount Debt-asset base units.
    /// @return preview The preview; `amount` is the part Aave repays.
    /// @custom:spec REQ-LENS-052
    function previewRepayAfter(
        address wallet,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 amount
    ) external view returns (ActionPreview memory preview);

    /// @notice Returns the account before and after pledging a position the wallet owns.
    /// @dev Reverts with the error the market's AMM integration's `validatePosition` raises for a position it would not
    /// accept.
    /// @param wallet The wallet, owner of the position.
    /// @param marketId The market.
    /// @param positionKey The position.
    /// @return preview The preview; `amount` is the units the pledge credits.
    /// @custom:spec REQ-LENS-053
    function previewPledgeAfter(
        address wallet,
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (ActionPreview memory preview);

    /// @notice Returns the account before and after withdrawing one of its records.
    /// @param wallet The wallet.
    /// @param marketId The account's market.
    /// @param positionKey The record's position.
    /// @return preview The preview; `amount` is the record's credited units after reconciliation, 0 when the position is
    /// no open record of the wallet's account.
    /// @custom:spec REQ-LENS-053
    function previewWithdrawAfter(
        address wallet,
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (ActionPreview memory preview);
}
