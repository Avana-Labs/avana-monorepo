// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICollateralizationDebtMark
/// @notice The indebted mark of an account, which `closeMarket` reads through `indebtedCount` (Q-355).
/// @dev The mark moves no charge and no counter other than `indebtedCount`. Market caps are set at listing and watched
/// by monitoring; a non-borrowing LP that holds cap room is an accepted risk (AMMN-FLOW-16, Q-396). The market of a
/// proxy is the one Collateralization recorded at its first pledge (`vt`). Every function requires the Lock held by its
/// named caller (`NotAdapter`, `NotLPVaultSwap`, `LockNotHeld`).
/// @custom:spec REQ-COLL-038, REQ-COLL-039, REQ-COLL-040, Q-355, Q-396
interface ICollateralizationDebtMark {
    /// @notice Marks the account indebted inside every borrow.
    /// @dev AaveAdapter only, Lock held by the Adapter, called after `preBorrowCheck`. Sets `indebted[proxy] = true`,
    /// incrementing `indebtedCount[vt]` when the flag was false; otherwise changes nothing. Moves no charge.
    /// @param proxy The account.
    /// @custom:spec REQ-COLL-039
    function markIndebted(
        address proxy
    ) external;

    /// @notice Clears the account's indebted mark once its Spoke account has no debt.
    /// @dev AaveAdapter or LPVaultSwap, Lock held by the caller; the AaveAdapter calls it from its repays and from its
    /// permissionless `refreshDebtMark(proxy)`. Reads `getUserAccountData(proxy).borrowCount` on `vaultToken.spoke()`;
    /// when it is 0 and `indebted[proxy]` is set, clears the flag and decrements `indebtedCount[vt]`; otherwise, and
    /// when the read fails or returns short data, changes nothing. Reverts with `InsufficientGas` when the read fails
    /// with less than 50,000 gas left (a starved read), and never otherwise for an authorized caller. A stale mark only
    /// delays `closeMarket` until anyone calls `refreshDebtMark`; no exit reads it.
    /// @param proxy The account.
    /// @custom:spec REQ-COLL-040, Q-355
    function markDebtFree(
        address proxy
    ) external;
}
