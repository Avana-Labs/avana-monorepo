// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICollateralizationSeizure
/// @notice Seizure snapshot, seizure settlement with reconciliation and record debits in seizure order, and settlement
/// of the pending-settlement balance.
/// @dev Called only by LPVaultSwap while it holds the lock (`NotLPVaultSwap`, `LockNotHeld`). LPVaultSwap has the
/// AaveAdapter burn the seized units from its own balance (`burnSeized`) between `beginSeizure` and `settleSeizure`,
/// and before `settlePending`; Collateralization proves each burn with a supply check. Reads no price, pause or
/// policy. A seizure walks at most `MAX_RECORDS_PER_ACCOUNT_MARKET` = 16 records, so its gas is bounded by about
/// 1.31M + 16 x 0.29M = 5.95M on every chain (AMMN-GAS-01).
/// @custom:spec REQ-VAULT-046, REQ-VAULT-050, REQ-VAULT-063, REQ-VAULT-086, REQ-VAULT-138, REQ-COLL-008, Q-224, Q-369
interface ICollateralizationSeizure {
    /// @notice Snapshots the proxy's supplied shares and the token's total supply before LPVaultSwap calls
    /// `Spoke.liquidationCall`.
    /// @dev Validates the vault token (`InvalidVaultToken`); requires `Hub.getAddedAssets == Hub.getAddedShares` for the
    /// vault-token asset on the market's Hub (`SharesNotEqualAssets`), no active snapshot (`SeizureActive`) and
    /// `vaultToken.isValidProxy(proxy)` (`UnknownProxy`). Stores in transient storage `proxy`, `vaultToken`,
    /// `reserveId`, `sharesBefore = Spoke.getUserSuppliedShares(reserveId, proxy)` and `supplyBefore =
    /// vaultToken.totalSupply()`; no caller-supplied snapshot is accepted.
    /// @custom:spec REQ-VAULT-047, REQ-VAULT-048, REQ-VAULT-049, REQ-VAULT-112, REQ-VAULT-113, REQ-VAULT-114, REQ-VAULT-115, REQ-COLL-003, REQ-COLL-010, SPEC-BACK-007, INV-014, Q-160
    function beginSeizure(
        address proxy,
        address vaultToken
    ) external;

    /// @notice Checks the share drop and the supply drop, reconciles, debits records and has the market's LPVault
    /// unwind exactly their units to LPVaultSwap.
    /// @dev Requires an active snapshot for exactly this `proxy` and `vaultToken` (`SeizureMismatch`). Checks
    /// `sharesBefore - sharesAfter == units` (`DebitMismatch`) and `supplyBefore - totalSupply() == units`
    /// (`SupplyDropMismatch`). With `units == 0` it only checks the zero drops, clears the snapshot and returns zeros.
    /// Otherwise, in order: `checkReadSafe` (`PoolLocked`); reconcile the account-market with `sharesBefore`
    /// (principal of the shortfall goes to the pending balance); debit `units` from the seizure list per
    /// `SPEC-BACK-006` (`InsufficientCredit`); release exposure per record; subtract from the totals; clear the
    /// snapshot; then for each debited record call `LPVault.unwind(positionKey, take, zeros, LP_VAULT_SWAP)`, which
    /// returns only the removed principal (`SPEC-BACK-008`), so fees stay owed to the depositor. Finally requires the
    /// summed `amounts[i] >= minAmounts[i]` for every token (`BelowMinimum`), the per-token oracle minimums LPVaultSwap
    /// computed. A record debited to 0 stays open. Emits `RecordDebited` per record, `SeizureReconciled` if a shortfall
    /// was debited, and one `SeizureSettled`. Any failure reverts the whole liquidation.
    /// @param proxy The liquidated proxy.
    /// @param vaultToken The collateral market.
    /// @param units Seized vault-token units LPVaultSwap received from the Spoke and had the Adapter burn.
    /// @param minAmounts Per-token minimums of the summed unwind, pool order.
    /// @return amounts Summed raw principal per token unwound to LPVaultSwap, pool order.
    /// @custom:spec REQ-VAULT-010, REQ-VAULT-043, REQ-VAULT-051, REQ-VAULT-052, REQ-VAULT-053, REQ-VAULT-054, REQ-VAULT-055, REQ-VAULT-056, REQ-VAULT-057, REQ-VAULT-058, REQ-VAULT-059, REQ-VAULT-060, REQ-VAULT-061, REQ-VAULT-062, REQ-VAULT-105, REQ-VAULT-108, REQ-VAULT-116, REQ-VAULT-117, REQ-VAULT-133, REQ-VAULT-134, REQ-VAULT-135, REQ-VAULT-136, REQ-VAULT-146, REQ-AMM-CORE-007, SPEC-BACK-005, SPEC-BACK-006, SPEC-BACK-007, SPEC-BACK-008, SPEC-BACK-010, SPEC-BACK-011, LIQ-020, LIQ-021, LIQ-022, LIQ-023, LIQ-024, LIQ-025, INV-014, INV-015, INV-033, Q-224, Q-201, Q-216, Q-217
    function settleSeizure(
        address proxy,
        address vaultToken,
        uint256 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts);

    /// @notice Checks that units of an unsettled seizure were burned and pays the matching pending pool tokens to
    /// LPVaultSwap.
    /// @dev Requires a valid vault token (`InvalidVaultToken`), no active seizure snapshot (`SeizureActive`) and
    /// `0 < units <= pending[vaultToken].units` (`PendingExceeded`). Requires `vaultToken.totalSupply() + units <=
    /// totalCredited[vaultToken] + pending[vaultToken].units` (`SupplyDropMismatch`), so no pool token leaves for a
    /// unit still in circulation. Pays per `SPEC-BACK-012`: for each token i, `floor(pending.amounts[i] * units /
    /// pending.units)`, and the exact remainder when `units == pending.units`. Example: pending (units 1,000,
    /// amounts [600, 401]) and units 300: pays [180, 120], leaving (700, [420, 281]); the last 700 units pay [420, 281].
    /// Transfers each non-zero amount to `LP_VAULT_SWAP` and emits `PendingSettled`. A reverting pool token reverts
    /// the call and leaves the balance for a later settlement.
    /// @return amounts Raw amounts per token paid to LPVaultSwap, pool order.
    /// @custom:spec REQ-VAULT-137, REQ-VAULT-139, REQ-VAULT-141, REQ-VAULT-142, REQ-VAULT-145, REQ-VAULT-146, REQ-COLL-012, SPEC-BACK-009, SPEC-BACK-012, Q-201, Q-211, Q-217, Q-257
    function settlePending(
        address vaultToken,
        uint256 units
    ) external returns (uint256[] memory amounts);
}
