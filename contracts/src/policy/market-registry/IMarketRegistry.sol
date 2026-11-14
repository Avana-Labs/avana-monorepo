// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryApprovals} from "./IMarketRegistryApprovals.sol";
import {IMarketRegistryBreakers} from "./IMarketRegistryBreakers.sol";
import {IMarketRegistryCreditLines} from "./IMarketRegistryCreditLines.sol";
import {IMarketRegistryErrors} from "./IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "./IMarketRegistryEvents.sol";
import {IMarketRegistryFreeze} from "./IMarketRegistryFreeze.sol";
import {IMarketRegistryHubs} from "./IMarketRegistryHubs.sol";
import {IMarketRegistryListing} from "./IMarketRegistryListing.sol";
import {IMarketRegistryPause} from "./IMarketRegistryPause.sol";
import {IMarketRegistryRouteViews} from "./IMarketRegistryRouteViews.sol";
import {IMarketRegistryRoutes} from "./IMarketRegistryRoutes.sol";
import {IMarketRegistrySafetyEvents} from "./IMarketRegistrySafetyEvents.sol";
import {IMarketRegistryStandby} from "./IMarketRegistryStandby.sol";
import {IMarketRegistryViews} from "./IMarketRegistryViews.sol";
import {IMarketRegistryWindDown} from "./IMarketRegistryWindDown.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title IMarketRegistry
/// @notice The chain's registry of Hubs, AMM integrations, CDP Spokes and their debt reserves (with funding Hub and
/// First-Loss Reserve), cross-Hub credit lines, markets and their status, listed pool tokens and debt assets with their
/// primary, alternate and standby Chainlink routes, swap routes,
/// each Hub's pause state (None, Frozen, Paused) with its reason, the latched circuit breakers and the address freeze.
/// @dev Deployed behind one fixed ERC-1967 proxy (UUPS); `_authorizeUpgrade` requires `APPLICATION_ADMIN`, held only
/// by the Avana timelock, so upgrades take the normal delay. ERC-7201 namespace `avana.storage.MarketRegistry`; the
/// implementation constructor calls `_disableInitializers()` and takes the implementation immutables
/// `VAULT_TOKEN_FACTORY`, `AAVE_ADAPTER`, `COLLATERALIZATION`, `PROXY_MANAGER`, `PARAMETER_STORE`, `RISK_MODULE`,
/// `LP_VAULT_SWAP`, `TIMELOCK`, `AAVE_GOVERNANCE_EXECUTOR`, `LOCK` and `PAYOUT_ESCROW`. No Hub,
/// AMM position manager or factory, flash source or debt asset is an immutable: Hubs, integrations (each LPVault and
/// pricing implementation), First-Loss Reserves and the IFlashSource come from storage, so one registry serves every Hub
/// and AMM protocol on the chain and a new one needs no redeploy; `_grantRole` reverts `AdminRoleOnlyTimelock` for a
/// grant of either admin role to any account but `TIMELOCK`. Roles are OpenZeppelin AccessControl:
/// `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` belong to the timelock only; `APPLICATION_PAUSE_GUARDIAN` and
/// `APPLICATION_FREEZE_GUARDIAN` (admin `APPLICATION_ADMIN`) belong to the Emergency Guardian and the Aave Protocol
/// Guardian. Writes require `APPLICATION_ADMIN` except the guardian calls (pause state and reason, address freeze,
/// breaker trips and resets, standby switch), `cancelStandbySwitch` (Aave governance executor) and the RiskModule's
/// `recordBreach`; the three deployment operations `deployCdpSpoke`,
/// `listCollateralMarket` and `enableDebtReserve` are timelock operations; each function's developer note names its delay class (normal 5 days,
/// short 12 hours). The registry stores no risk parameter (those live in the
/// ParameterStore), holds no token or NFT and calls no state-changing function elsewhere. Immutable Avana contracts
/// never read Spoke, Hub, reserve IDs, debt asset or pool from it. Every view is `view`, never reverts for a listed key and
/// returns the values in force at the current block.
/// @custom:spec REQ-CONFIG-001, REQ-CONFIG-002, REQ-CONFIG-003, REQ-CONFIG-004, REQ-CONFIG-005, REQ-CONFIG-014, REQ-CONFIG-064, REQ-CONFIG-069, REQ-MREG-005, Q-226, Q-227, Q-228, Q-240, Q-241, Q-242, Q-248, Q-252, Q-259, Q-376, Q-378, Q-379
interface IMarketRegistry is
    IAccessControl,
    IMarketRegistryEvents,
    IMarketRegistrySafetyEvents,
    IMarketRegistryErrors,
    IMarketRegistryListing,
    IMarketRegistryHubs,
    IMarketRegistryRoutes,
    IMarketRegistryPause,
    IMarketRegistryFreeze,
    IMarketRegistryBreakers,
    IMarketRegistryStandby,
    IMarketRegistryCreditLines,
    IMarketRegistryWindDown,
    IMarketRegistryApprovals,
    IMarketRegistryViews,
    IMarketRegistryRouteViews
{}
