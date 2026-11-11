// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CounterKind} from "./types/CounterKind.sol";

/// @title ICollateralizationEvents
/// @notice Events of collateral accounting: pledges and releases of records, record debits, partial removals,
/// deleverage releases and re-credits, seizure settlement and reconciliation, pending settlement, and exposure counters
/// clamped at 0.
/// @dev Indexers key collateral by `chainId + Collateralization + recordId`; a position is
/// `(integrationId, positionKey)`. Amount arrays are in the market's pool token order.
/// @custom:spec REQ-VAULT-022, REQ-VAULT-062, REQ-VAULT-073, REQ-VAULT-136, Q-076
interface ICollateralizationEvents {
    /// @notice A record was written for a pledged position.
    /// @dev Emitted by `pledge` after the record and counters are written; the Adapter mints `credited` to `proxy`
    /// and emits `CollateralAdded` after the supply in the same transaction.
    /// @param recordId New record ID.
    /// @param positionKey Pledged position.
    /// @param depositor Depositor of record (the wallet that called the Adapter).
    /// @param integrationId AMM integration of the position.
    /// @param proxy The depositor's PositionProxy that receives and supplies the units.
    /// @param vaultToken The market's vault token.
    /// @param credited Credited units, the units the Adapter mints.
    /// @param usdCharge Cap charge returned by the RiskModule and booked, USD 8 decimals.
    /// @param sliceUsd Part of `usdCharge` booked in the market's top-up slice, USD 8 decimals.
    /// @custom:spec REQ-VAULT-022, SPEC-BACK-004, DEP-012
    event CollateralPledged(
        uint256 indexed recordId,
        bytes32 indexed positionKey,
        address indexed depositor,
        uint32 integrationId,
        address proxy,
        address vaultToken,
        uint128 credited,
        uint256 usdCharge,
        uint256 sliceUsd
    );

    /// @notice A record was closed and the LPVault returned its whole position to the depositor of record.
    /// @dev Emitted by `release` and by a `releaseForDeleverage` of every credited unit (`unitsBurned` = the units the
    /// Adapter burned) and by `releaseZeroCredit` (`unitsBurned` = 0).
    /// @param recordId The closed record.
    /// @param positionKey The released position.
    /// @param depositor Recipient of the position.
    /// @param proxy The record's proxy.
    /// @param vaultToken The record's market.
    /// @param unitsBurned Vault-token units burned for this release.
    /// @custom:spec REQ-VAULT-073, REQ-VAULT-075
    event CollateralReleased(
        uint256 indexed recordId,
        bytes32 indexed positionKey,
        address indexed depositor,
        address proxy,
        address vaultToken,
        uint256 unitsBurned
    );

    /// @notice One record was debited, in a seizure settlement or in a reconciliation.
    /// @dev For a seizure the principal goes to LPVaultSwap; for a reconciliation it goes to the pending balance.
    /// @param recordId The debited record.
    /// @param positionKey The record's position.
    /// @param proxy The account's proxy.
    /// @param vaultToken The market.
    /// @param unitsDebited Units removed from the record and the position.
    /// @param creditedAfter Credited units left on the record.
    /// @param amounts Raw principal per token unwound.
    /// @param capReleased USD (8 decimals) of exposure released per `SPEC-BACK-005`.
    /// @custom:spec REQ-VAULT-062, REQ-VAULT-136, SPEC-BACK-005
    event RecordDebited(
        uint256 indexed recordId,
        bytes32 indexed positionKey,
        address indexed proxy,
        address vaultToken,
        uint256 unitsDebited,
        uint256 creditedAfter,
        uint256[] amounts,
        uint256 capReleased
    );

    /// @notice A seizure settlement completed.
    /// @param proxy The liquidated proxy.
    /// @param vaultToken The market.
    /// @param units Seized units debited (burned by the Adapter before the call).
    /// @param amounts Total raw principal per token unwound to LPVaultSwap for this seizure.
    /// @param recordsDebited Number of records debited for this seizure.
    /// @custom:spec REQ-VAULT-062
    event SeizureSettled(
        address indexed proxy, address indexed vaultToken, uint256 units, uint256[] amounts, uint256 recordsDebited
    );

    /// @notice A reconciliation debited an account-market's shortfall into the pending-settlement balance.
    /// @param proxy The account's proxy.
    /// @param vaultToken The market.
    /// @param units Shortfall debited, per `SPEC-BACK-011`.
    /// @param amounts Raw principal per token added to the pending balance.
    /// @custom:spec REQ-VAULT-136, SPEC-BACK-011, Q-201
    event SeizureReconciled(address indexed proxy, address indexed vaultToken, uint256 units, uint256[] amounts);

    /// @notice Burned units of an unsettled seizure were settled and their pending pool tokens sent to LPVaultSwap.
    /// @param vaultToken The market.
    /// @param units Units the Adapter burned for this settlement.
    /// @param amounts Raw amounts per token paid to LPVaultSwap.
    /// @custom:spec REQ-VAULT-139, SPEC-BACK-012, Q-201
    event PendingSettled(address indexed vaultToken, uint256 units, uint256[] amounts);

    /// @notice An exposure counter subtraction was clamped at 0.
    /// @dev Exits never revert on counter arithmetic; saturation is a bug alarm for monitoring.
    /// @param counterKind Which counter was clamped.
    /// @param hub Hub that scopes the counter (the market's Hub).
    /// @param key Vault token, pool token or depositor wallet that keys the counter.
    /// @param valueBefore Counter value before the subtraction.
    /// @param subtracted Amount that was to be subtracted (USD 8 decimals).
    /// @custom:spec REQ-VAULT-037, REQ-VAULT-127
    event CounterSaturated(
        CounterKind counterKind, address indexed hub, address key, uint256 valueBefore, uint256 subtracted
    );

    /// @notice A record was reduced by a partial removal or a deleverage release.
    /// @dev The record stays open after a partial removal; a deleverage release of every credited unit also emits
    /// `CollateralReleased`.
    /// @param recordId The reduced record.
    /// @param units Credited units debited (burned by the Adapter before the call).
    /// @param release USD (8 decimals) of exposure released per `SPEC-BACK-005`.
    /// @custom:spec REQ-COLL-014, REQ-COLL-017, SPEC-BACK-005, Q-254, Q-255
    event RecordReduced(uint256 indexed recordId, uint128 units, uint256 release);

    /// @notice Units added to a pledged position were credited to its record.
    /// @param recordId The re-credited record.
    /// @param added Units credited, minted by the Adapter to the record's proxy.
    /// @param charge USD (8 decimals) booked for the added units.
    /// @param rescueUnits Rescue units booked by this re-credit.
    /// @custom:spec REQ-COLL-015, SPEC-BACK-013, SPEC-BACK-014, DEP-023, Q-254
    event RecordRecredited(uint256 indexed recordId, uint128 added, uint256 charge, uint128 rescueUnits);
}
