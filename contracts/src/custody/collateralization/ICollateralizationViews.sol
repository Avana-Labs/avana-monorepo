// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {BackingRecord} from "./types/BackingRecord.sol";
import {Pending} from "./types/Pending.sol";

/// @title ICollateralizationViews
/// @notice Read-only views of the backing ledger: records, credited totals, pending settlement and exposure counters.
/// @dev Ledger views revert `Locked` while another address holds the lock.
interface ICollateralizationViews {
    /// @notice Returns an open backing record.
    /// @dev A missing record returns a zeroed struct.
    function getRecord(
        uint256 recordId
    ) external view returns (BackingRecord memory record);

    /// @notice Returns the open record of a position.
    /// @return recordId The open record ID, or 0 if none.
    function recordIdOf(
        uint32 integrationId,
        bytes32 positionKey
    ) external view returns (uint256 recordId);

    /// @notice Returns the next record ID; every ID below it has been assigned.
    function nextRecordId() external view returns (uint256 nextId);

    /// @notice Returns one page of an account-market's open records: seizure list, then records at 0 credited units.
    function getAccountRecords(
        address proxy,
        address vaultToken,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory recordIds, BackingRecord[] memory records);

    /// @notice Returns the number of open records of an account-market, including records at 0 credited units.
    function getOpenRecordCount(
        address proxy,
        address vaultToken
    ) external view returns (uint256 count);

    /// @notice Returns the sum of credited units over an account-market's open records.
    function getAccountCredited(
        address proxy,
        address vaultToken
    ) external view returns (uint256 credited);

    /// @notice Returns the sum of credited units of the market's open records.
    /// @dev `vaultToken.totalSupply() <= totalCredited + pending.units` at the end of every transaction.
    function getTotalCredited(
        address vaultToken
    ) external view returns (uint256 totalCredited);

    /// @notice Returns the credited units summed over every market of one pool on the chain.
    function poolUnits(
        bytes32 poolKey
    ) external view returns (uint256 units);

    /// @notice Returns the market's pending-settlement balance.
    /// @return pending Unsettled units and the pool tokens backing them, pool order.
    function getPending(
        address vaultToken
    ) external view returns (Pending memory pending);

    /// @notice Returns one page of a market's open records in the order of the market's record index.
    function getMarketRecords(
        address vaultToken,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory recordIds, BackingRecord[] memory records);

    /// @notice Number of open records of a market.
    function getMarketRecordCount(
        address vaultToken
    ) external view returns (uint256 count);

    /// @notice Whether no account of the market carries the indebted mark.
    function getMarketDebtFree(
        address vaultToken
    ) external view returns (bool debtFree);

    /// @notice Returns the exposure counters a pledge into `vaultToken` would touch, USD with 8 decimals.
    /// @param depositor Unused; no counter is kept per depositor.
    function getCounters(
        address vaultToken,
        address depositor
    ) external view returns (PledgeCounters memory counters);

    /// @notice Returns the units a withdrawal of a record must use, after reconciling the current shortfall.
    function previewRelease(
        uint32 integrationId,
        bytes32 positionKey
    ) external view returns (uint256 units);

    /// @notice Returns the units a re-credit of a record would credit now.
    /// @dev Reverts `RecordNotFound` for no open record.
    function previewRecredit(
        uint32 integrationId,
        bytes32 positionKey
    ) external view returns (uint128 added);

    /// @notice Returns the sum of rescue units over an account-market's open records.
    function getAccountRescueUnits(
        address proxy,
        address vaultToken
    ) external view returns (uint256 rescueUnits);

    /// @notice Returns the AaveAdapter, the only caller of the pledge and release functions.
    function ADAPTER() external view returns (address adapter);

    /// @notice Returns the registered LPVault of an integration identifier, from the VaultTokenFactory.
    /// @return lpVault The LPVault, or address(0) when unregistered.
    function lpVaultOf(
        uint32 integrationId
    ) external view returns (address lpVault);

    /// @notice Returns LPVaultSwap, the only caller of the seizure and pending functions.
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Returns the RiskModule called by `pledge`.
    function RISK_MODULE() external view returns (address riskModule);

    /// @notice Returns the chain's Lock.
    function LOCK() external view returns (address lock);

    /// @notice Returns the chain's VaultTokenFactory.
    function VAULT_TOKEN_FACTORY() external view returns (address vaultTokenFactory);
}
