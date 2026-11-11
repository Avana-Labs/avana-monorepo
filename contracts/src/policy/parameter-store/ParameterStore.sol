// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {Market} from "../../types/Market.sol";
import {MarketStatus} from "../market-registry/types/MarketStatus.sol";
import {IParameterStore} from "./IParameterStore.sol";
import {IParameterStoreAdmin} from "./IParameterStoreAdmin.sol";
import {IParameterStoreBreakers} from "./IParameterStoreBreakers.sol";
import {IParameterStoreChain} from "./IParameterStoreChain.sol";
import {IParameterStoreCoverage} from "./IParameterStoreCoverage.sol";
import {IParameterStoreLiquidation} from "./IParameterStoreLiquidation.sol";
import {ParameterStoreForwardAdmin} from "./ParameterStoreForwardAdmin.sol";
import {ParameterStoreForwardRisk} from "./ParameterStoreForwardRisk.sol";
import {ParameterStoreRouter} from "./ParameterStoreRouter.sol";
import {ParameterStoreViews} from "./ParameterStoreViews.sol";
import {GlobalParams} from "./types/GlobalParams.sol";
import {ParameterStoreLogics} from "./types/ParameterStoreLogics.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title ParameterStore
/// @notice Every Avana risk and oracle parameter of one chain, with its hard bounds, liquidation-liveness bounds and
/// change direction; written by the chain's AvanaTimelock (tightenings and Avana's fee share also by the Joint
/// Configuration Safe's `APPLICATION_RISK_STEWARD`) and read by the RiskModule, MarketRegistry, LPOracle,
/// DebtOracle, LPVaultSwap, the IFlashSource, the Lens and monitoring.
/// @dev UUPS implementation behind one fixed ERC-1967 proxy; `_authorizeUpgrade` requires `APPLICATION_ADMIN`. It
/// serves every view itself and checks every setter's role itself; each setter body runs in one of five immutable
/// logic contracts by delegatecall (`ParameterStoreRouter`, `IParameterStoreLogic`), because the whole surface does
/// not fit the 24,576-byte code limit in one contract. All state is in the ERC-7201 namespace
/// `avana.storage.ParameterStore`. The store holds no token and makes only view calls besides those delegatecalls.
/// @custom:spec REQ-PSTORE-001, REQ-PSTORE-002, REQ-PSTORE-003, REQ-PSTORE-011, REQ-PSTORE-014, REQ-PSTORE-019, REQ-PSTORE-025, REQ-CONFIG-057, REQ-CONFIG-058, REQ-CONFIG-071, Q-226, Q-259, Q-381
contract ParameterStore is
    UUPSUpgradeable,
    ParameterStoreForwardRisk,
    ParameterStoreForwardAdmin,
    ParameterStoreViews,
    IParameterStore
{
    /// @notice Fixes the implementation immutables and the five logic contracts; see `ParameterStoreRouter`.
    /// @param timelock The chain's AvanaTimelock.
    /// @param marketRegistry The chain's MarketRegistry proxy.
    /// @param chainBlockTime Seconds per block (12 on Ethereum, 2 on Base).
    /// @param hasSequencer True on an L2 with a sequencer-uptime feed (Base), false on Ethereum.
    /// @param logics The five logic contracts.
    /// @custom:spec REQ-PSTORE-001, REQ-PSTORE-023, REQ-PSTORE-027
    constructor(
        address timelock,
        address marketRegistry,
        uint32 chainBlockTime,
        bool hasSequencer,
        ParameterStoreLogics memory logics
    ) ParameterStoreRouter(timelock, marketRegistry, chainBlockTime, hasSequencer, logics) {}

    /// @inheritdoc IParameterStoreAdmin
    /// @dev Grants both admin roles to `TIMELOCK` only and makes `APPLICATION_ADMIN` the admin of
    /// `APPLICATION_PAUSE_GUARDIAN` and `APPLICATION_RISK_STEWARD`; the parameter checks and writes run in the risk
    /// logic contract.
    /// @custom:spec REQ-PSTORE-001, REQ-CONFIG-050, REQ-PSTORE-016, REQ-PSTORE-018, REQ-PSTORE-023, REQ-PSTORE-030, Q-259
    function initialize(
        address timelock,
        GlobalParams calldata,
        uint256,
        uint16
    ) external override initializer {
        if (timelock != _TIMELOCK) revert AdminRoleOnlyTimelock(DEFAULT_ADMIN_ROLE, timelock);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _setRoleAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, AvanaRoles.APPLICATION_ADMIN);
        _setRoleAdmin(AvanaRoles.APPLICATION_RISK_STEWARD, AvanaRoles.APPLICATION_ADMIN);
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        _grantRole(AvanaRoles.APPLICATION_ADMIN, timelock);
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStoreLiquidation
    /// @custom:spec REQ-PSTORE-021, Q-261
    function liquidationLivenessHolds(
        address spoke,
        uint256 marketId,
        uint256 debtReserveId
    ) external view override returns (bool holds) {
        Market memory m = _REGISTRY.getMarket(marketId);
        if (m.status == MarketStatus.None || spoke == address(0) || m.spoke != spoke) return false;
        if (!_REGISTRY.isApprovedDebtReserve(spoke, debtReserveId)) return false;
        holds = _inequality(_minLb(m), _s().market[marketId].slippageAllowanceMinBps, _s().g.maxFlashFeeBps);
    }

    /// @inheritdoc IParameterStoreLiquidation
    /// @custom:spec REQ-PSTORE-018
    function maxShortfallBps() external view override returns (uint16 value) {
        value = _s().g.maxShortfallBps;
    }

    /// @inheritdoc IParameterStoreLiquidation
    /// @custom:spec REQ-PSTORE-020
    function debtStressRiseBps(
        address asset
    ) external view override returns (uint16 value) {
        value = _s().debtStressRiseBps[asset];
    }

    /// @inheritdoc IParameterStoreLiquidation
    /// @custom:spec REQ-PSTORE-022
    function aaveTargetHealthFactor(
        address spoke
    ) external view override returns (uint256 value) {
        value = _s().targetHealthFactor[spoke];
    }

    /// @inheritdoc IParameterStoreLiquidation
    /// @custom:spec REQ-PSTORE-022
    function minLiquidationBonus(
        address spoke
    ) external view override returns (uint16 value) {
        value = _s().minLiquidationBonus[spoke];
    }

    /// @inheritdoc IParameterStoreBreakers
    /// @custom:spec REQ-PSTORE-016, SPEC-BRK-004
    function breakerDeficitMax(
        address hub,
        address asset
    ) external view override returns (uint256 value) {
        value = _s().breakerDeficitMax[hub][asset];
    }

    /// @inheritdoc IParameterStoreBreakers
    /// @custom:spec REQ-PSTORE-030, SPEC-BRK-007
    function gateRecoverySeconds() external view override returns (uint64 value) {
        value = _s().g.gateRecoverySeconds;
    }

    /// @inheritdoc IParameterStoreChain
    /// @custom:spec REQ-PSTORE-023
    function sequencer() external view override returns (address feed, uint32 gracePeriod) {
        (feed, gracePeriod) = (_s().sequencer.feed, _s().sequencer.gracePeriod);
    }

    /// @inheritdoc IParameterStoreChain
    /// @custom:spec REQ-PSTORE-027, SPEC-ORC-022
    function CHAIN_BLOCK_TIME() external view override returns (uint32 value) {
        value = _BLOCK_TIME;
    }

    /// @inheritdoc IParameterStoreChain
    /// @custom:spec REQ-PSTORE-027, SPEC-ORC-022, Q-326
    function twapMinObservations(
        uint256 marketId
    ) external view override returns (uint16 count) {
        count = _twapMinObservations(_s().market[marketId].twapWindow);
    }

    /// @inheritdoc IParameterStoreChain
    /// @custom:spec REQ-CONFIG-023, SPEC-ORC-019, Q-322
    function heartbeatMargin(
        address feed
    ) external view override returns (uint32 margin) {
        margin = _s().feeds[feed].heartbeatMargin;
    }

    /// @inheritdoc IParameterStoreCoverage
    /// @custom:spec REQ-PSTORE-032
    function coverageRatioBps() external view override returns (uint16 value) {
        value = _s().coverageRatioBps;
    }

    /// @inheritdoc IParameterStoreBreakers
    /// @custom:spec REQ-PSTORE-030, REQ-ACCESS-165, Q-399
    function tightenGateRecoverySeconds(
        uint64
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreBreakers
    /// @custom:spec REQ-PSTORE-030, REQ-ACCESS-165, Q-399
    function loosenGateRecoverySeconds(
        uint64
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreBreakers
    /// @custom:spec REQ-PSTORE-016, REQ-CONFIG-049, REQ-CONFIG-051
    function tightenBreakerDeficitMax(
        address,
        address,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreBreakers
    /// @custom:spec REQ-PSTORE-016, REQ-CONFIG-049, REQ-CONFIG-053
    function loosenBreakerDeficitMax(
        address,
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLiquidation
    /// @custom:spec REQ-PSTORE-018, REQ-CONFIG-049, REQ-CONFIG-051
    function tightenMaxShortfallBps(
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLiquidation
    /// @custom:spec REQ-PSTORE-018, REQ-CONFIG-049, REQ-CONFIG-053
    function loosenMaxShortfallBps(
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLiquidation
    /// @custom:spec REQ-PSTORE-020, REQ-CONFIG-049, REQ-CONFIG-051
    function tightenDebtStressRiseBps(
        address,
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLiquidation
    /// @custom:spec REQ-PSTORE-020, REQ-CONFIG-049, REQ-CONFIG-053
    function loosenDebtStressRiseBps(
        address,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLiquidation
    /// @custom:spec REQ-PSTORE-022, REQ-CONFIG-049, REQ-CONFIG-054
    function setLiquidationExpectations(
        address,
        uint256,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStoreChain
    /// @custom:spec REQ-PSTORE-023, REQ-ORACLE-099, SPEC-ORC-021, Q-324
    function setSequencer(
        address,
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStoreCoverage
    /// @custom:spec REQ-PSTORE-032, REQ-CONFIG-049
    function setCoverageRatioBps(
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @dev Only `APPLICATION_ADMIN` (the timelock) upgrades, at the normal delay.
    /// @custom:spec REQ-PSTORE-001
    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}
}
