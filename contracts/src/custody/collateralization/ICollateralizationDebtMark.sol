// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICollateralizationDebtMark
/// @notice The indebted mark of an account, which `closeMarket` reads through `indebtedCount`.
interface ICollateralizationDebtMark {
    /// @notice Marks the account indebted inside every borrow.
    /// @dev AaveAdapter only.
    function markIndebted(
        address proxy
    ) external;

    /// @notice Clears the account's indebted mark once its Spoke account has no debt.
    /// @dev AaveAdapter or LPVaultSwap. Reverts `InsufficientGas` if the Spoke read was starved.
    function markDebtFree(
        address proxy
    ) external;
}
