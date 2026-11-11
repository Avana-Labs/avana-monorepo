// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICollateralizationUser
/// @notice Depositor actions that need no debt check: release of a record at 0 credited units and fee collection,
/// reached through the AaveAdapter.
/// @dev Both require `msg.sender == ADAPTER` and the lock held by the Adapter (`NotAdapter`, `LockNotHeld`): the Lock
/// has exactly two members, so the depositor calls `AaveAdapter.releaseZeroCredit` or `AaveAdapter.collectFees`, which
/// passes `msg.sender` as `depositor`. Neither reads a pause state, breaker, freeze, price or policy, so both work in
/// every application state.
/// @custom:spec REQ-VAULT-075, REQ-COLL-008, Q-134, Q-223, Q-371
interface ICollateralizationUser {
    /// @notice Returns the position of a record at 0 credited units to its depositor.
    /// @dev Requires an open record for `(vaultToken.integrationId(), positionKey)` (`RecordNotFound`) and
    /// `depositor == record.depositor` (`NotDepositor`); reconciles the account-market with `Spoke.getUserSuppliedShares(reserveId, record.proxy)` (skipped while Hub
    /// added assets differ from added shares); requires `credited == 0` (`RecordHasCredit`); closes the record and
    /// calls `returnPosition(positionKey)` on the market's LPVault. Makes no debt check, no burn and no pause or
    /// policy call. Emits `CollateralReleased` with `unitsBurned = 0`.
    /// @param depositor The wallet that called the Adapter.
    /// @param vaultToken The record's market.
    /// @param positionKey The record's position in the market's integration.
    /// @custom:spec REQ-VAULT-033, REQ-VAULT-074, REQ-VAULT-076, REQ-VAULT-086, REQ-VAULT-119, REQ-VAULT-121, REQ-VAULT-130, REQ-VAULT-132, REQ-VAULT-140, REQ-VAULT-143, REQ-COLL-011, Q-201
    function releaseZeroCredit(
        address depositor,
        address vaultToken,
        bytes32 positionKey
    ) external;

    /// @notice Collects every owed fee of a record's position to its depositor.
    /// @dev Requires an open record (`RecordNotFound`) and `depositor == record.depositor` (`NotDepositor`); calls
    /// `collectFees(positionKey, depositor)` on the market's LPVault, which pays the depositor directly. No unit or
    /// counter changes. Reverts with `FeesRolledIn` for an AMM protocol whose fees compound into the position.
    /// @param depositor The wallet that called the Adapter.
    /// @param vaultToken The record's market.
    /// @param positionKey The record's position in the market's integration.
    /// @return amounts Raw fees collected per token, pool order.
    /// @custom:spec REQ-VAULT-064, REQ-VAULT-065, REQ-VAULT-066, REQ-VAULT-120, REQ-VAULT-126, REQ-AMM-CORE-011, FEE-001, FEE-006
    function collectFees(
        address depositor,
        address vaultToken,
        bytes32 positionKey
    ) external returns (uint256[] memory amounts);
}
