// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CollateralizationBase} from "./CollateralizationBase.sol";
import {CollateralizationDebtMark} from "./CollateralizationDebtMark.sol";
import {CollateralizationPending} from "./CollateralizationPending.sol";
import {CollateralizationPledge} from "./CollateralizationPledge.sol";
import {CollateralizationRelease} from "./CollateralizationRelease.sol";
import {CollateralizationSeizure} from "./CollateralizationSeizure.sol";
import {CollateralizationViews} from "./CollateralizationViews.sol";
import {ICollateralization} from "./ICollateralization.sol";

/// @title Collateralization
/// @notice The chain's one immutable, AMM-neutral backing ledger (2.3): one record per pledged position keyed by
/// (`integrationId`, `positionKey`), the largest-first seizure list of each account and market, the credited totals,
/// the pending-settlement balance of unsettled seizures and the USD exposure counters keyed by Hub.
/// @dev No proxy, no `delegatecall`, no `selfdestruct`, no owner, no pause, no setter, no sweep, no generic call,
/// multicall or ERC-1271. Every state change is reachable only from the AaveAdapter or LPVaultSwap while it holds the
/// Lock; Collateralization never acquires or releases the Lock itself. The implementation is split by concern: the
/// Adapter path (`CollateralizationPledge`, `CollateralizationRelease`), the seizure (`CollateralizationSeizure`), the
/// pending settlement (`CollateralizationPending`), the debt mark (`CollateralizationDebtMark`) and the views
/// (`CollateralizationViews`), over shared storage and checks (`CollateralizationBase`, `CollateralizationLedger`).
/// Constructor arguments are the CREATE3-predicted addresses of the Adapter proxy, LPVaultSwap, the RiskModule, the
/// Lock and the VaultTokenFactory; each must be non-zero and distinct.
/// @custom:spec REQ-COLL-001, REQ-COLL-002, REQ-COLL-004, REQ-COLL-009, REQ-COLL-029, REQ-COLL-030, REQ-VAULT-023, REQ-VAULT-087, REQ-VAULT-090, REQ-VAULT-092, REQ-LOCK-010, REQ-LOCK-028, REQ-LOCK-030, INV-052, INV-091
contract Collateralization is
    CollateralizationPledge,
    CollateralizationRelease,
    CollateralizationSeizure,
    CollateralizationPending,
    CollateralizationDebtMark,
    CollateralizationViews,
    ICollateralization
{
    /// @custom:spec REQ-COLL-001, REQ-COLL-002
    constructor(
        address adapter,
        address lpVaultSwap,
        address riskModule,
        address lock,
        address vaultTokenFactory
    ) CollateralizationBase(adapter, lpVaultSwap, riskModule, lock, vaultTokenFactory) {}
}
