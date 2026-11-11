// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationAdapter} from "./ICollateralizationAdapter.sol";
import {ICollateralizationDebtMark} from "./ICollateralizationDebtMark.sol";
import {ICollateralizationErrors} from "./ICollateralizationErrors.sol";
import {ICollateralizationEvents} from "./ICollateralizationEvents.sol";
import {ICollateralizationSeizure} from "./ICollateralizationSeizure.sol";
import {ICollateralizationUser} from "./ICollateralizationUser.sol";
import {ICollateralizationViews} from "./ICollateralizationViews.sol";

/// @title ICollateralization
/// @notice The chain's one AMM-neutral backing ledger: position validation through the market's AMM integration,
/// credited units returned to the AaveAdapter for minting, backing records per account and market, partial removal,
/// re-credit and deleverage release of a record, rescue units, the seizure order and checks, reconciliation of
/// unsettled seizures, the pending-settlement balance, the USD exposure counters keyed by Hub and the credited-unit
/// counter keyed by pool.
/// @dev Non-upgradeable: no proxy, no `delegatecall`, no `selfdestruct`, no owner, no pause, no setter, no sweep, no
/// generic call, multicall or ERC-1271. Holds no position and no vault token; moves positions and units only through
/// the market's LPVault and holds only the pool tokens of the pending balances. Market identity comes only from
/// validated vault-token immutables and the VaultTokenFactory's append-only integration registry, so a new AMM
/// protocol, Hub, Spoke or market never needs a new ledger. Constructor arguments: `adapter`, `lpVaultSwap`,
/// `riskModule`, `lock`, `vaultTokenFactory` (CREATE3-predicted addresses, checked at deployment). Entry points that
/// move value are reachable only from the AaveAdapter and LPVaultSwap, the Lock's two members. At the end of every
/// transaction `vt.totalSupply() <= totalCredited[vt] + pending[vt].units` for every market, with equality while every
/// `burnSeized` is followed in the same call by the `settleSeizure` or `settlePending` that debits it. Units: position
/// units equal vault-token base units (multiplier 1); USD amounts have 8 decimals; token arrays are in pool order.
/// @custom:spec REQ-COLL-001, REQ-COLL-002, REQ-COLL-004, REQ-COLL-005, REQ-COLL-006, REQ-COLL-008, REQ-COLL-009, REQ-VAULT-028, REQ-VAULT-029, REQ-VAULT-030, REQ-VAULT-031, REQ-VAULT-032, REQ-VAULT-087, REQ-VAULT-088, REQ-VAULT-089, REQ-VAULT-090, REQ-VAULT-092, SPEC-BACK-009, SPEC-BACK-010, INV-001, INV-002, INV-005, INV-052, INV-053, Q-224, Q-226, Q-240, Q-257, Q-369, Q-371
interface ICollateralization is
    ICollateralizationEvents,
    ICollateralizationErrors,
    ICollateralizationAdapter,
    ICollateralizationUser,
    ICollateralizationSeizure,
    ICollateralizationDebtMark,
    ICollateralizationViews
{}
