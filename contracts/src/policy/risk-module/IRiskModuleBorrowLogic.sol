// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";

/// @title IRiskModuleBorrowLogic
/// @notice The borrow-side pre-checks, the rescue-excluded health check and the debt value.
interface IRiskModuleBorrowLogic is IRiskModuleLogic {
    /// @notice Body of `preBorrowCheck` (`borrow = true`) and `preWithdrawCheck`: the scope, the pokes, then `gate`.
    /// @param debtReserveId The reserve borrowed (ignored when `borrow` is false).
    function preCheck(
        address proxy,
        uint256 debtReserveId,
        bool borrow
    ) external;

    /// @notice The same gates without the pokes, on the stored oracle state; reverts with the first failing gate.
    /// @param debtReserveId The reserve borrowed, or `type(uint256).max` for none.
    function gate(
        address proxy,
        uint256 debtReserveId,
        bool borrow
    ) external view;

    /// @notice Body of `IRiskModule.postHealthCheck`.
    function postHealthCheck(
        address proxy,
        uint256 minHealthFactor
    ) external view returns (uint256 healthFactor);

    /// @notice Aave's health factor of the account and the rescue-excluded one.
    /// @return hf Aave's health factor, WAD.
    /// @return hfEx The rescue-excluded health factor, WAD.
    function healthFactors(
        address proxy
    ) external view returns (uint256 hf, uint256 hfEx);

    /// @notice Body of `IRiskModule.debtValueUsd`.
    function debtValueUsd(
        address proxy
    ) external view returns (uint256 usd);
}
