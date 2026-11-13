// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreAdmin} from "./IParameterStoreAdmin.sol";
import {IParameterStoreBreakers} from "./IParameterStoreBreakers.sol";
import {IParameterStoreChain} from "./IParameterStoreChain.sol";
import {IParameterStoreCoverage} from "./IParameterStoreCoverage.sol";
import {IParameterStoreErrors} from "./IParameterStoreErrors.sol";
import {IParameterStoreEvents} from "./IParameterStoreEvents.sol";
import {IParameterStoreLiquidation} from "./IParameterStoreLiquidation.sol";
import {IParameterStoreListing} from "./IParameterStoreListing.sol";
import {IParameterStoreLoosen} from "./IParameterStoreLoosen.sol";
import {IParameterStoreRiskViews} from "./IParameterStoreRiskViews.sol";
import {IParameterStoreSpeed} from "./IParameterStoreSpeed.sol";
import {IParameterStoreTighten} from "./IParameterStoreTighten.sol";
import {IParameterStoreViews} from "./IParameterStoreViews.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title IParameterStore
/// @notice Every Avana risk parameter of one chain with its hard bounds, liquidation-liveness bounds and change direction: market
/// parameters and caps, `minPledgeUsd`, token collateral factors and tolerances, Chainlink feed definitions, debt-reserve
/// buy slippage and its liveness floor, route depth thresholds, global oracle and settlement values, fees,
/// circuit-breaker thresholds, the caller shortfall bound, each debt
/// asset's stress rise, each CDP Spoke's expected liquidation configuration, and the oracle configuration each
/// LPOracle reads, and the per-chain values (sequencer grace, block time) of `IParameterStoreChain`; there is no minimum debt (`Q-381`).
/// Parameters are kept per chain, per Hub, per Spoke, per market, per feed and per debt asset as each one applies;
/// no value assumes one Hub, one debt asset or one AMM protocol.
/// @dev Deployed behind one fixed ERC-1967 proxy (UUPS); `_authorizeUpgrade` requires `APPLICATION_ADMIN`. ERC-7201
/// namespace `avana.storage.ParameterStore`; the implementation constructor calls `_disableInitializers()` and takes
/// the implementation immutables `TIMELOCK`, `MARKET_REGISTRY`, the hard bound of every
/// parameter, the loosening steps and the liveness bounds `graceHealthFactorMin`, `graceDurationMax` and
/// `consistencyToleranceMinBps`, and `CHAIN_BLOCK_TIME`. Roles are OpenZeppelin AccessControl: `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` belong
/// to `TIMELOCK` only, and `_grantRole` reverts `AdminRoleOnlyTimelock` for any other grantee; every setter requires
/// `APPLICATION_ADMIN`, and the tighten setters and `setAvanaFeeShareBps` also accept `APPLICATION_RISK_STEWARD`, held by
/// the Joint Configuration Safe, which calls them at once (REQ-PSTORE-002). The ParameterStore entries of the timelock's immutable `SHORT_ELIGIBLE` are exactly the
/// `tighten…` selectors of `IParameterStoreTighten`, `IParameterStoreLiquidation` (`tightenMaxShortfallBps`, `tightenDebtStressRiseBps`), `IParameterStoreBreakers`
/// (`tightenBreakerDeficitMax`, `tightenGateRecoverySeconds`), `IParameterStoreAdmin` (`tightenMaxFlashFeeBps`) and `IParameterStoreSpeed` (`tightenMarketSpeedLimits`, `tightenDebtSpeedLimit`), each of which accepts only a strictly
/// safer value; every other setter and upgrades take the
/// normal delay. Step-limited loosenings move one step at most once per `normalDelay`.
/// No guardian holds a function here except `useStandbySecondSource` (`APPLICATION_PAUSE_GUARDIAN`, REQ-PSTORE-029), no
/// value has a temporary override, and every value is the one the last executed timelock operation or risk-steward call
/// set; the steward only tightens and moves Avana's fee share within its bound. The store holds no token or NFT and makes only view calls. Every view is `view`, never
/// reverts for a listed key, and returns zeros for an unknown key so age and usability checks fail closed.
/// @custom:spec REQ-PSTORE-001, REQ-PSTORE-002, REQ-PSTORE-003, REQ-PSTORE-011, REQ-PSTORE-014, REQ-PSTORE-017, REQ-CONFIG-049, REQ-CONFIG-050, REQ-CONFIG-051, REQ-CONFIG-053, REQ-CONFIG-054, REQ-CONFIG-057, REQ-CONFIG-058, REQ-CONFIG-071, REQ-ACCESS-155, Q-226, Q-228, Q-240, Q-246, Q-259, Q-262, Q-380
interface IParameterStore is
    IAccessControl,
    IParameterStoreEvents,
    IParameterStoreErrors,
    IParameterStoreTighten,
    IParameterStoreLoosen,
    IParameterStoreAdmin,
    IParameterStoreListing,
    IParameterStoreViews,
    IParameterStoreRiskViews,
    IParameterStoreBreakers,
    IParameterStoreLiquidation,
    IParameterStoreChain,
    IParameterStoreCoverage,
    IParameterStoreSpeed
{}
