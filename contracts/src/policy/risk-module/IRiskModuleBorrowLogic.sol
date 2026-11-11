// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";

/// @title IRiskModuleBorrowLogic
/// @notice The borrow-side pre-checks, the rescue-excluded health check and the debt value.
interface IRiskModuleBorrowLogic is IRiskModuleLogic {
    /// @notice Body of `preBorrowCheck` (`borrow = true`) and `preWithdrawCheck` (`borrow = false`): the scope, the
    /// oracle pokes, then `gate`.
    /// @param proxy The account.
    /// @param debtReserveId The reserve borrowed (ignored when `borrow` is false).
    /// @param borrow True for a borrow.
    /// @custom:spec REQ-RISK-056, REQ-ADAPTER-024, REQ-ADAPTER-025
    function preCheck(
        address proxy,
        uint256 debtReserveId,
        bool borrow
    ) external;

    /// @notice The same gates without the pokes, on the stored oracle state; reverts with the first failing gate.
    /// @param proxy The account.
    /// @param debtReserveId The reserve borrowed, or `type(uint256).max` for none.
    /// @param borrow True for a borrow.
    /// @custom:spec REQ-RISK-060, REQ-ADAPTER-038
    function gate(
        address proxy,
        uint256 debtReserveId,
        bool borrow
    ) external view;

    /// @notice Body of `IRiskModuleChecks.postHealthCheck`.
    /// @custom:spec REQ-RISK-068, SPEC-CF-005
    function postHealthCheck(
        address proxy,
        uint256 minHealthFactor
    ) external view returns (uint256 healthFactor);

    /// @notice Aave's health factor of the account and the rescue-excluded one (SPEC-CF-005).
    /// @param proxy The account.
    /// @return hf Aave's health factor, WAD.
    /// @return hfEx The rescue-excluded health factor, WAD.
    /// @custom:spec SPEC-CF-005
    function healthFactors(
        address proxy
    ) external view returns (uint256 hf, uint256 hfEx);

    /// @notice Body of `IRiskModuleViews.debtValueUsd`.
    /// @custom:spec SPEC-CAP-009
    function debtValueUsd(
        address proxy
    ) external view returns (uint256 usd);
}
