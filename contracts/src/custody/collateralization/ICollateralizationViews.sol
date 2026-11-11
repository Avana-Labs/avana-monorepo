// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {BackingRecord} from "./types/BackingRecord.sol";
import {Pending} from "./types/Pending.sol";

/// @title ICollateralizationViews
/// @notice Backing records, the seizure list of each account and market, credited-unit totals, the pending-settlement
/// balance, the exposure counters a pledge touches, and the units a withdrawal must use.
/// @dev Every ledger view reverts with `Locked` while the lock is held, unless the caller is the current lock holder,
/// which reads only after its call into Collateralization has returned (the Adapter's backing check).
/// `getAccountRescueUnits` and `poolUnits` instead answer while the lock is free or held by the AaveAdapter, for the
/// RiskModule's checks inside the Adapter's calls. The immutable getters never revert.
/// @custom:spec REQ-VAULT-091, REQ-VAULT-128, REQ-COLL-002
interface ICollateralizationViews {
    /// @notice Returns an open backing record.
    /// @dev The call reverts with `Locked` while the lock is held by another address. A missing record returns a zeroed struct.
    /// @param recordId The record ID.
    /// @return record The record.
    /// @custom:spec REQ-VAULT-091, REQ-VAULT-128
    function getRecord(
        uint256 recordId
    ) external view returns (BackingRecord memory record);

    /// @notice Returns the open record of a position.
    /// @dev The call reverts with `Locked` while the lock is held by another address.
    /// @param integrationId The position's AMM integration.
    /// @param positionKey The position's key in that integration.
    /// @return recordId The open record ID, or 0 if none.
    /// @custom:spec REQ-VAULT-091, REQ-AMM-CORE-001
    function recordIdOf(
        uint32 integrationId,
        bytes32 positionKey
    ) external view returns (uint256 recordId);

    /// @notice Returns the next record ID; every ID below it has been assigned.
    /// @dev Starts at 1. The call reverts with `Locked` while the lock is held by another address.
    /// @return nextId The ID the next pledge receives.
    /// @custom:spec REQ-VAULT-091, REQ-VAULT-128
    function nextRecordId() external view returns (uint256 nextId);

    /// @notice Returns one page of an account-market's open records: its seizure list in list order, then its records
    /// at 0 credited units.
    /// @dev The seizure list is largest credited first at insertion, ties by lowest record ID, and holds only records
    /// with credited units. At most `limit` entries starting at position `offset`; an `offset` past the end returns
    /// empty arrays.
    /// The call reverts with `Locked` while the lock is held by another address.
    /// @param proxy The account's proxy.
    /// @param vaultToken The market.
    /// @param offset Position of the first record returned.
    /// @param limit Maximum number of records.
    /// @return recordIds Record IDs of the page.
    /// @return records Records of the page, in the same order.
    /// @custom:spec REQ-VAULT-091, REQ-VAULT-128, SPEC-BACK-006, Q-194
    function getAccountRecords(
        address proxy,
        address vaultToken,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory recordIds, BackingRecord[] memory records);

    /// @notice Returns the number of open records of an account-market, including records at 0 credited units.
    /// @dev Never above `MAX_RECORDS_PER_ACCOUNT_MARKET` = 16 (AMMN-GAS-01). The call reverts with `Locked` while the lock is held by another address.
    /// @param proxy The account's proxy.
    /// @param vaultToken The market.
    /// @return count Open record count.
    /// @custom:spec REQ-VAULT-091, REQ-VAULT-128
    function getOpenRecordCount(
        address proxy,
        address vaultToken
    ) external view returns (uint256 count);

    /// @notice Returns the sum of credited units over an account-market's open records.
    /// @dev The call reverts with `Locked` while the lock is held by another address.
    /// @param proxy The account's proxy.
    /// @param vaultToken The market.
    /// @return credited `accountCredited[proxy][vaultToken]`, position units.
    /// @custom:spec REQ-VAULT-091, REQ-VAULT-128, REQ-VAULT-129, INV-008
    function getAccountCredited(
        address proxy,
        address vaultToken
    ) external view returns (uint256 credited);

    /// @notice Returns the sum of credited units of the market's open records.
    /// @dev `vaultToken.totalSupply() <= totalCredited + pending.units` at the end of every transaction, with equality
    /// under a conforming LPVaultSwap; the Adapter reads it as the lock holder before its first mint, burn or
    /// Collateralization call and after its last one, for its backing-gap check. The call reverts with `Locked` while
    /// the lock is held by another address.
    /// @param vaultToken The market.
    /// @return totalCredited Credited units, position units.
    /// @custom:spec REQ-VAULT-029, REQ-VAULT-091, REQ-VAULT-128, SPEC-BACK-009, INV-001, DEP-018, Q-257
    function getTotalCredited(
        address vaultToken
    ) external view returns (uint256 totalCredited);

    /// @notice Returns the credited units summed over every market (range) of one pool on the chain.
    /// @dev `poolKey = keccak256(abi.encode(integrationId, pool, poolId))`. Every credit and debit of a market's record
    /// moves this counter by the same units, so it equals the sum of `getTotalCredited` over the pool's markets. The
    /// RiskModule's pool-share cap reads it (SPEC-CAP-005, AMMN-RT-05). An out-of-range market's units still count.
    /// Readable while the lock is free or held by the AaveAdapter (the RiskModule's borrow-side market breaker reads it
    /// inside the Adapter's borrow and withdrawal-with-debt calls); reverts with `Locked` while another member holds it.
    /// @param poolKey The pool.
    /// @return units Credited units, position units.
    /// @custom:spec SPEC-CAP-005, REQ-RISK-079, INV-092, REQ-COLL-018
    function poolUnits(
        bytes32 poolKey
    ) external view returns (uint256 units);

    /// @notice Returns the market's pending-settlement balance.
    /// @dev The call reverts with `Locked` while the lock is held by another address.
    /// @param vaultToken The market.
    /// @return pending Unsettled units and the pool tokens backing them, pool order.
    /// @custom:spec REQ-VAULT-091, REQ-VAULT-128, REQ-VAULT-137
    function getPending(
        address vaultToken
    ) external view returns (Pending memory pending);

    /// @notice Returns one page of a market's open records in the order of the market's record index.
    /// @dev Records enter the index in record-ID order; closing a record moves the last entry into its place. The
    /// call reverts with `Locked` while the lock is held by another address. Returns empty arrays for `limit == 0` or
    /// an `offset` at or beyond `getMarketRecordCount`.
    /// @param vaultToken The market.
    /// @param offset Position of the first record returned.
    /// @param limit Maximum number of records.
    /// @return recordIds Record IDs.
    /// @return records The records.
    /// @custom:spec REQ-VAULT-091, REQ-VAULT-128
    function getMarketRecords(
        address vaultToken,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory recordIds, BackingRecord[] memory records);

    /// @notice Number of open records of a market.
    /// @param vaultToken The market.
    /// @return count Open records.
    /// @custom:spec REQ-VAULT-091, REQ-VAULT-128
    function getMarketRecordCount(
        address vaultToken
    ) external view returns (uint256 count);

    /// @notice Whether no account of the market carries the indebted mark (`indebtedCount[vaultToken] == 0`).
    /// @dev Read by the MarketRegistry's `closeMarket` (2.8 `REQ-CONFIG-080`). A stale mark only delays the close.
    /// @param vaultToken The market.
    /// @return debtFree True when no account is marked indebted.
    /// @custom:spec REQ-COLL-040, Q-355
    function getMarketDebtFree(
        address vaultToken
    ) external view returns (bool debtFree);

    /// @notice Returns the exposure counters a pledge into `vaultToken` by `depositor` would touch.
    /// @dev USD with 8 decimals; the same values `pledge` passes to `checkPledge`. Token and depositor counters are
    /// keyed by the market's Hub, so they sum every Spoke and market of that Hub on this chain (AMMN-RT-05). The call
    /// reverts with `Locked` while the lock is held by another address.
    /// @param vaultToken The market.
    /// @param depositor The depositor wallet.
    /// @return counters Hub, market regular and slice counters, depositor counter, pool key and pool units, and
    /// per-token counters in pool order; `accountRecords` is 0 because no proxy is named (`getOpenRecordCount`).
    /// @custom:spec REQ-VAULT-034, REQ-VAULT-091, REQ-VAULT-128, SPEC-BACK-004, INV-027, Q-369
    function getCounters(
        address vaultToken,
        address depositor
    ) external view returns (PledgeCounters memory counters);

    /// @notice Returns the units a withdrawal of a record must use, after reconciling the current shortfall.
    /// @dev Computed per `SPEC-BACK-011` with the proxy's current supplied shares; 0 means the record would be fully
    /// reconciled and is released with `releaseZeroCredit`. A partial removal must use fewer units. Fails with `RecordNotFound` for no open record and with
    /// `Locked` while the lock is held by another address.
    /// @param integrationId The position's AMM integration.
    /// @param positionKey The record's position.
    /// @return units Credited units after reconciliation.
    /// @custom:spec REQ-VAULT-091, REQ-VAULT-119, REQ-VAULT-128, SPEC-BACK-011
    function previewRelease(
        uint32 integrationId,
        bytes32 positionKey
    ) external view returns (uint256 units);

    /// @notice Returns the units a re-credit of a record would credit now.
    /// @dev The position's live units above its credited units after reconciling the current shortfall; 0 for a record
    /// at 0 credited units. Fails with `RecordNotFound` for no open record and with `Locked` while the lock is held by
    /// another address.
    /// @param integrationId The position's AMM integration.
    /// @param positionKey The record's position.
    /// @return added Units `recredit` would credit and the Adapter would mint.
    /// @custom:spec REQ-COLL-018, REQ-VAULT-091, REQ-VAULT-128, Q-254
    function previewRecredit(
        uint32 integrationId,
        bytes32 positionKey
    ) external view returns (uint128 added);

    /// @notice Returns the sum of rescue units over an account-market's open records.
    /// @dev Rescue units are valued at zero by the RiskModule's health check after a borrow, a withdrawal with debt or a
    /// partial removal with debt; Aave counts them in full. Readable while the lock is free or held by the AaveAdapter
    /// (the RiskModule reads it inside the Adapter's calls); reverts with `Locked` while another member holds it.
    /// @param proxy The account's proxy.
    /// @param vaultToken The market.
    /// @return rescueUnits `accountRescueUnits[proxy][vaultToken]`, position units.
    /// @custom:spec REQ-COLL-016, REQ-COLL-018, SPEC-BACK-014, Q-253
    function getAccountRescueUnits(
        address proxy,
        address vaultToken
    ) external view returns (uint256 rescueUnits);

    /// @notice Returns the chain's AaveAdapter fixed proxy address, the only caller of `pledge`, `release`,
    /// `releasePartial`, `recredit`, `releaseForDeleverage`, `releaseZeroCredit` and `collectFees`.
    /// @return adapter Constructor immutable.
    /// @custom:spec REQ-COLL-002, REQ-VAULT-086
    function ADAPTER() external view returns (address adapter);

    /// @notice Returns the registered LPVault (AMM integration) of an integration identifier, read from the
    /// VaultTokenFactory's append-only registry.
    /// @param integrationId The integration.
    /// @return lpVault The LPVault, or address(0) when unregistered.
    /// @custom:spec REQ-COLL-002, REQ-COLL-004, REQ-AMM-CORE-001
    function lpVaultOf(
        uint32 integrationId
    ) external view returns (address lpVault);

    /// @notice Returns the LPVaultSwap fixed proxy address, the only caller of the seizure and pending functions.
    /// @return lpVaultSwap Constructor immutable.
    /// @custom:spec REQ-COLL-002, REQ-VAULT-086
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Returns the RiskModule fixed proxy address called by `pledge`.
    /// @return riskModule Constructor immutable.
    /// @custom:spec REQ-COLL-002, REQ-VAULT-014
    function RISK_MODULE() external view returns (address riskModule);

    /// @notice Returns the chain's Lock.
    /// @return lock Constructor immutable.
    /// @custom:spec REQ-COLL-002, REQ-VAULT-086
    function LOCK() external view returns (address lock);

    /// @notice Returns the chain's VaultTokenFactory, the registry of vault tokens and AMM integrations.
    /// @return vaultTokenFactory Constructor immutable.
    /// @custom:spec REQ-COLL-002, REQ-COLL-003
    function VAULT_TOKEN_FACTORY() external view returns (address vaultTokenFactory);
}
