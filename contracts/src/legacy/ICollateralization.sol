// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PledgeCounters} from "../types/PositionTypes.sol";
import {BackingRecord, Pending} from "./CollateralizationTypes.sol";
import {ICollateralizationBase} from "./ICollateralizationBase.sol";

/// @title ICollateralization
/// @notice The chain's AMM-neutral backing ledger for vault-token collateral.
/// @dev Not upgradeable, no owner. Value-moving functions are reachable only from the AaveAdapter and LPVaultSwap.
interface ICollateralization is ICollateralizationBase {
    /// @notice Takes custody of a position, books its charge and writes its record; returns the units to mint.
    /// @param depositor The wallet that called `Adapter.pledge`; becomes the depositor of record.
    /// @param requireRescue True when only a rescue top-up may pass.
    function pledge(
        address depositor,
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        bool requireRescue
    ) external returns (uint256 recordId, uint128 credited);

    /// @notice Debits a record's units after the Adapter burned them, closes it and returns the position.
    /// @dev `units` must equal the record's credited units after reconciliation.
    function release(
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        uint256 units
    ) external;

    /// @notice Debits part of a record after the Adapter burned it and releases that principal to the depositor.
    /// @dev Requires `0 < units < record.credited`.
    function releasePartial(
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint128 remaining, uint256[] memory amounts);

    /// @notice Credits the live units a depositor added to a pledged position; returns the units to mint.
    /// @param topUp Encoded LP amount the LPVault pulls from the depositor; empty for an NFT integration.
    function recredit(
        address depositor,
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        bytes calldata topUp,
        bool requireRescue
    ) external returns (uint128 added, uint128 rescueUnits);

    /// @notice Debits a record by units burned in a repay with collateral and unwinds them to LPVaultSwap.
    /// @dev Requires `0 < units <= record.credited`.
    /// @return amounts Principal per token unwound to LPVaultSwap, pool order.
    function releaseForDeleverage(
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts, bool closed);

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

    /// @notice Snapshots the proxy's supplied shares and the token's supply before `Spoke.liquidationCall`.
    function beginSeizure(
        address proxy,
        address vaultToken
    ) external;

    /// @notice Checks the share and supply drops, debits records and unwinds the seized units to LPVaultSwap.
    /// @dev The supply drop must equal `units`; any extra share drop is Aave's liquidation fee and goes to pending.
    /// @param units Seized units LPVaultSwap received and had the Adapter burn.
    /// @param minAmounts Per-token minimums of the summed unwind, pool order.
    /// @return amounts Principal per token unwound to LPVaultSwap, pool order.
    function settleSeizure(
        address proxy,
        address vaultToken,
        uint256 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts);

    /// @notice Pays LPVaultSwap the pending pool tokens matching burned units of an unsettled seizure.
    /// @dev Pro-rata share rounded down; the exact remainder when settling all pending units.
    function settlePending(
        address vaultToken,
        uint256 units
    ) external returns (uint256[] memory amounts);

    /// @notice Returns the position of a record at 0 credited units to its depositor.
    function releaseZeroCredit(
        address depositor,
        address vaultToken,
        bytes32 positionKey
    ) external;

    /// @notice Collects every owed fee of a record's position to its depositor.
    /// @return amounts Fees collected per token, pool order.
    function collectFees(
        address depositor,
        address vaultToken,
        bytes32 positionKey
    ) external returns (uint256[] memory amounts);

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

    /// @notice Returns the LegacyRiskModule called by `pledge`.
    function RISK_MODULE() external view returns (address riskModule);

    /// @notice Returns the chain's Lock.
    function LOCK() external view returns (address lock);

    /// @notice Returns the chain's VaultTokenFactory.
    function VAULT_TOKEN_FACTORY() external view returns (address vaultTokenFactory);
}
