// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ActionPreview} from "./types/ActionPreview.sol";

/// @title ILensActions
/// @notice An account's health factor and liquidation price before and after one borrow, repay, pledge or withdrawal.
interface ILensActions {
    /// @notice Returns the account before and after borrowing `amount` of a debt reserve.
    /// @param amount Debt-asset base units.
    function previewBorrowAfter(
        address wallet,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 amount
    ) external view returns (ActionPreview memory preview);

    /// @notice Returns the account before and after repaying `amount` of a debt reserve (capped at the debt).
    /// @param amount Debt-asset base units.
    /// @return preview The preview; `amount` is the part Aave repays.
    function previewRepayAfter(
        address wallet,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 amount
    ) external view returns (ActionPreview memory preview);

    /// @notice Returns the account before and after pledging a position the wallet owns.
    /// @dev Reverts with the AMM integration's `validatePosition` error for a position it would not accept.
    /// @return preview The preview; `amount` is the units the pledge credits.
    function previewPledgeAfter(
        address wallet,
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (ActionPreview memory preview);

    /// @notice Returns the account before and after withdrawing one of its records.
    /// @return preview The preview; `amount` is the record's credited units, 0 when it is not an open record.
    function previewWithdrawAfter(
        address wallet,
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (ActionPreview memory preview);
}
