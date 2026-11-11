// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICollateralizationErrors
/// @notice Errors of collateral accounting: caller and lock checks, vault-token validation, the record limit, the
/// pledge charge, record lookups, the seizure snapshot, debit and supply checks, pending settlement and views called while
/// the lock is held.
/// @dev Position errors (pool, range, ownership, pool lock) are raised by the market's LPVault (`ILPVaultErrors`) and
/// propagate unchanged.
/// @custom:spec REQ-VAULT-092, Q-224, Q-369
interface ICollateralizationErrors {
    /// @notice `pledge`, `release`, `releasePartial`, `recredit`, `releaseForDeleverage`, `releaseZeroCredit` or
    /// `collectFees` was called by an address other than the AaveAdapter.
    /// @custom:spec REQ-VAULT-006, REQ-VAULT-068, REQ-VAULT-113, REQ-COLL-014, REQ-COLL-015, REQ-COLL-017
    error NotAdapter();

    /// @notice `beginSeizure`, `settleSeizure` or `settlePending` was called by an address other than LPVaultSwap.
    /// @custom:spec REQ-VAULT-046, REQ-VAULT-050, REQ-VAULT-113, REQ-VAULT-138
    error NotLPVaultSwap();

    /// @notice An inner entry point was called while the lock is not held by its named caller.
    /// @custom:spec REQ-VAULT-006, REQ-VAULT-046, REQ-VAULT-050, REQ-VAULT-068, REQ-VAULT-112, REQ-VAULT-138
    error LockNotHeld();

    /// @notice The vault token is not registered in the VaultTokenFactory, is bound to another Collateralization,
    /// Adapter, LPVaultSwap or LPVault than the registered one for its integration, or is not the record's market.
    /// @custom:spec REQ-COLL-003, REQ-VAULT-068, REQ-VAULT-102
    error InvalidVaultToken();

    /// @notice The proxy is not registered in the market's vault token.
    /// @param proxy The rejected proxy.
    /// @custom:spec REQ-VAULT-013, REQ-VAULT-048, REQ-COLL-010
    error UnknownProxy(address proxy);

    /// @notice The account-market already holds `MAX_RECORDS_PER_ACCOUNT_MARKET` = 16 open records; add value to an
    /// existing record with a re-credit instead (AMMN-GAS-01).
    /// @param openRecords Open records of the account-market.
    /// @custom:spec REQ-VAULT-025, REQ-AMM-CORE-002, Q-369
    error TooManyRecords(uint256 openRecords);

    /// @notice An n-token array has a length other than the market's token count.
    /// @param expected Market token count.
    /// @param actual Array length.
    /// @custom:spec REQ-AMM-CORE-002
    error LengthMismatch(uint256 expected, uint256 actual);

    /// @notice A summed seizure unwind returned less than a per-token minimum.
    /// @param index Token index in pool order.
    /// @param received Raw amount received.
    /// @param minimum Raw minimum.
    /// @custom:spec REQ-AMM-CORE-007
    error BelowMinimum(uint256 index, uint256 received, uint256 minimum);

    /// @notice The position already backs an open record.
    /// @custom:spec REQ-VAULT-027, REQ-VAULT-106
    error AlreadyPledged();

    /// @notice The position's units read after custody, or a record's credited units after a re-credit, exceed
    /// `type(uint120).max`.
    /// @custom:spec REQ-VAULT-012, REQ-VAULT-107, SPEC-BACK-002
    error LiquidityAboveBound();

    /// @notice `checkPledge` returned `usdCharge == 0`, `usdCharge >= 2^64`, `sliceUsd > usdCharge`, rescue units
    /// above the units credited (or below them for a rescue pledge), or a re-credit's rebased charge reached `2^64` (the
    /// packed record stores charges as `uint64`, 184 billion USD at 8 decimals).
    /// @custom:spec REQ-VAULT-015, REQ-VAULT-110, SPEC-BACK-003, SPEC-BACK-013, SPEC-BACK-014
    error InvalidCharge();

    /// @notice No open record exists for the position.
    /// @custom:spec REQ-VAULT-068, REQ-VAULT-075, REQ-VAULT-119
    error RecordNotFound();

    /// @notice `release`, `releasePartial`, `recredit` or `releaseForDeleverage` named a proxy other than the
    /// record's.
    /// @custom:spec REQ-VAULT-068, REQ-VAULT-113
    error NotRecordProxy();

    /// @notice `release` units are 0 or differ from the record's credited units after reconciliation;
    /// `releasePartial` units are 0; `releaseForDeleverage` units are 0 or above the credited units.
    /// @custom:spec REQ-VAULT-069, REQ-VAULT-118, REQ-VAULT-143, REQ-COLL-017
    error UnitsMismatch();

    /// @notice The depositor named by `releaseZeroCredit`, `collectFees` or `recredit` is not the depositor of record.
    /// @custom:spec REQ-VAULT-075, REQ-VAULT-120, REQ-COLL-011, REQ-COLL-022
    error NotDepositor();

    /// @notice `releaseZeroCredit` was called for a record that still has credited units after reconciliation.
    /// @custom:spec REQ-VAULT-075, REQ-VAULT-121, REQ-VAULT-143
    error RecordHasCredit();

    /// @notice Hub added assets differ from added shares for the vault-token asset at `beginSeizure`.
    /// @custom:spec REQ-VAULT-047, REQ-VAULT-114, Q-189
    error SharesNotEqualAssets();

    /// @notice A seizure snapshot is already active at `beginSeizure` or `settlePending`.
    /// @custom:spec REQ-VAULT-048, REQ-VAULT-115, REQ-VAULT-138
    error SeizureActive();

    /// @notice No active snapshot matches the `proxy` and `vaultToken` of `settleSeizure`.
    /// @custom:spec REQ-VAULT-050, REQ-VAULT-115
    error SeizureMismatch();

    /// @notice The proxy's supplied-share drop since `beginSeizure` differs from the seized units.
    /// @custom:spec REQ-VAULT-051, REQ-VAULT-116, SPEC-BACK-007
    error DebitMismatch();

    /// @notice The vault token's supply check failed: in `settleSeizure` the drop since `beginSeizure` differs from
    /// `units`; in `settlePending` `totalSupply + units` exceeds `totalCredited + pending.units`.
    /// @param expected The supply drop (`settleSeizure`) or the largest supply (`settlePending`) the check admits.
    /// @param actual The measured supply drop or supply.
    /// @custom:spec REQ-VAULT-051, REQ-VAULT-116, REQ-VAULT-139, REQ-COLL-012, SPEC-BACK-007, SPEC-BACK-012, Q-257
    error SupplyDropMismatch(uint256 expected, uint256 actual);

    /// @notice Seized units exceed the account-market's credited units left after reconciliation.
    /// @custom:spec REQ-VAULT-055, REQ-VAULT-117, SPEC-BACK-006
    error InsufficientCredit();

    /// @notice `settlePending` was called with `units == 0` or `units > pending[vaultToken].units`.
    /// @custom:spec REQ-VAULT-138, REQ-VAULT-141
    error PendingExceeded();

    /// @notice A view was called while the lock is held, by an address other than the holder (for
    /// `getAccountRescueUnits` and `poolUnits`: while LPVaultSwap holds it).
    /// @custom:spec REQ-VAULT-091, REQ-VAULT-125, REQ-COLL-018
    error Locked();

    /// @notice `pledge` named the zero address, a registered LPVault or Collateralization as depositor; the last two
    /// would let a stray position an LPVault holds be pledged, and the zero address cannot receive a returned position.
    /// @param depositor The rejected depositor.
    /// @custom:spec REQ-VAULT-007, REQ-COLL-005, REQ-COLL-019, Q-258
    error InvalidDepositor(address depositor);

    /// @notice `markDebtFree`'s Spoke read failed with less than `DEBT_MARK_GAS_FLOOR` gas left, so the failure may be
    /// gas starvation by the caller rather than a failing read; the whole call reverts instead of keeping a stale mark.
    /// @param gasLeft Gas left after the failed read.
    /// @param required `DEBT_MARK_GAS_FLOOR`.
    /// @custom:spec REQ-COLL-040
    error InsufficientGas(uint256 gasLeft, uint256 required);

    /// @notice `releasePartial` asked for at least the record's credited units after reconciliation; a full exit is a
    /// withdrawal of the position.
    /// @param units The units requested.
    /// @param credited The record's credited units after reconciliation.
    /// @custom:spec REQ-COLL-014, REQ-COLL-020, Q-254
    error PartialRemovalTooLarge(uint128 units, uint128 credited);

    /// @notice `recredit` found a record at 0 credited units or no live units above its credited units.
    /// @param positionKey The record's position.
    /// @custom:spec REQ-COLL-015, REQ-COLL-021, REQ-VAULT-074, Q-254
    error NothingToRecredit(bytes32 positionKey);

    /// @notice `pledge` named a proxy whose records belong to another market; a proxy is bound to the vault token of
    /// its first pledge and never changes market (AMMN-FLOW-07).
    /// @param proxy The rejected proxy.
    /// @custom:spec REQ-COLL-031, REQ-COLL-034, Q-304
    error ProxyMarketMismatch(address proxy);

    /// @notice After custody the LPVault reported the position under a market other than the vault token's.
    /// @custom:spec REQ-COLL-024, REQ-COLL-035, Q-293
    error ShapeMismatch();

    /// @notice The LPVault's `receivePosition` returned 0 units.
    /// @custom:spec REQ-VAULT-012, REQ-VAULT-107
    error ZeroUnits();
}
