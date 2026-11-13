// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CloseAccountView} from "./types/CloseAccountView.sol";
import {DeleverageSizing} from "./types/DeleverageSizing.sol";
import {RemovalSizing} from "./types/RemovalSizing.sol";

/// @title ILensSizing
/// @notice Inverse sizing for the app: the largest collateral removal that keeps a target health factor, the smallest
/// repay with collateral that reaches one, and everything an account repays and withdraws to close.
interface ILensSizing {
    /// @notice Returns the most units the account can withdraw and stay at or above a target health factor, and which
    /// of its records it can withdraw alone.
    /// @param wallet The wallet.
    /// @param marketId The account's market.
    /// @param targetHealthFactor Target, WAD; raised to `max(1e18, hardHealthFloor)` with debt.
    /// @return sizing The sizing.
    /// @custom:spec REQ-LENS-054
    function previewMaxWithdraw(
        address wallet,
        uint256 marketId,
        uint256 targetHealthFactor
    ) external view returns (RemovalSizing memory sizing);

    /// @notice Returns the fewest units of one record whose repay with collateral brings the account to a target health
    /// factor.
    /// @param wallet The wallet.
    /// @param marketId The account's market.
    /// @param positionKey The record's position.
    /// @param debtReserveId The debt reserve to repay.
    /// @param targetHealthFactor Target, WAD; raised to 1e18.
    /// @return sizing The sizing.
    /// @custom:spec REQ-LENS-055, REQ-LENS-032
    function previewDeleverageTo(
        address wallet,
        uint256 marketId,
        bytes32 positionKey,
        uint256 debtReserveId,
        uint256 targetHealthFactor
    ) external view returns (DeleverageSizing memory sizing);

    /// @notice Returns every debt the account repays (with its repay-all spend cap for `deadline`) and every record it
    /// withdraws to close.
    /// @param wallet The wallet.
    /// @param marketId The account's market.
    /// @param deadline Last `block.timestamp` the repay-all calls may be included at.
    /// @return close The view; empty before the proxy is deployed.
    /// @custom:spec REQ-LENS-056
    function previewCloseAccount(
        address wallet,
        uint256 marketId,
        uint256 deadline
    ) external view returns (CloseAccountView memory close);
}
