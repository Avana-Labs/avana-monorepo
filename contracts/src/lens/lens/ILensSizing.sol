// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CloseAccountView} from "./types/CloseAccountView.sol";
import {DeleverageSizing} from "./types/DeleverageSizing.sol";
import {RemovalSizing} from "./types/RemovalSizing.sol";

/// @title ILensSizing
/// @notice Inverse sizing views: max withdrawal, deleverage to a target health factor, and account close.
interface ILensSizing {
    /// @notice Returns the most units the account can withdraw and keep a target health factor.
    /// @param targetHealthFactor Target, WAD; raised to `max(1e18, hardHealthFloor)` with debt.
    function previewMaxWithdraw(
        address wallet,
        uint256 marketId,
        uint256 targetHealthFactor
    ) external view returns (RemovalSizing memory sizing);

    /// @notice Returns the fewest units of one record whose repay with collateral reaches a target health factor.
    /// @param targetHealthFactor Target, WAD; raised to 1e18.
    function previewDeleverageTo(
        address wallet,
        uint256 marketId,
        bytes32 positionKey,
        uint256 debtReserveId,
        uint256 targetHealthFactor
    ) external view returns (DeleverageSizing memory sizing);

    /// @notice Returns every debt the account repays and every record it withdraws to close.
    /// @param deadline Last `block.timestamp` the repay-all calls may be included at.
    /// @return close The view; empty before the proxy is deployed.
    function previewCloseAccount(
        address wallet,
        uint256 marketId,
        uint256 deadline
    ) external view returns (CloseAccountView memory close);
}
