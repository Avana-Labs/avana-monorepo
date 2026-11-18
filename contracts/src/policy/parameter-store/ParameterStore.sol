// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {IParameterStore} from "./IParameterStore.sol";
import {IParameterStoreAdmin} from "./IParameterStoreAdmin.sol";
import {IParameterStoreBreakers} from "./IParameterStoreBreakers.sol";
import {IParameterStoreChain} from "./IParameterStoreChain.sol";
import {IParameterStoreCoverage} from "./IParameterStoreCoverage.sol";
import {IParameterStoreLiquidation} from "./IParameterStoreLiquidation.sol";
import {ParameterStoreForwardAdmin} from "./ParameterStoreForwardAdmin.sol";
import {ParameterStoreForwardRisk} from "./ParameterStoreForwardRisk.sol";
import {ParameterStoreForwardSpeed} from "./ParameterStoreForwardSpeed.sol";
import {ParameterStoreRouter} from "./ParameterStoreRouter.sol";
import {ParameterStoreViews} from "./ParameterStoreViews.sol";
import {GlobalParams} from "./types/GlobalParams.sol";
import {ParameterStoreLogics} from "./types/ParameterStoreLogics.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title ParameterStore
/// @notice Every Avana risk and oracle parameter of one chain, with its bounds and change direction.
/// @dev UUPS proxy; only the timelock can upgrade it. Setter bodies run in five logic contracts by delegatecall.
contract ParameterStore is
    UUPSUpgradeable,
    ParameterStoreForwardRisk,
    ParameterStoreForwardAdmin,
    ParameterStoreForwardSpeed,
    ParameterStoreViews,
    IParameterStore
{
    /// @notice Fixes the implementation immutables and the five logic contracts.
    constructor(
        address timelock,
        address marketRegistry,
        uint32 chainBlockTime,
        bool hasSequencer,
        ParameterStoreLogics memory logics
    ) ParameterStoreRouter(timelock, marketRegistry, chainBlockTime, hasSequencer, logics) {}

    /// @inheritdoc IParameterStoreAdmin
    function initialize(
        address timelock,
        GlobalParams calldata,
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
    /// @dev Runs in the oracle-admin logic, whose return data ends the call; the `return` below is not reached.
    function liquidationLivenessHolds(
        address,
        uint256,
        uint256
    ) external view override returns (bool holds) {
        _forwardView(_ADMIN_ORACLE_LOGIC);
        return holds;
    }

    /// @inheritdoc IParameterStoreLiquidation
    function maxShortfallBps() external view override returns (uint16 value) {
        value = _s().g.maxShortfallBps;
    }

    /// @inheritdoc IParameterStoreLiquidation
    function debtStressRiseBps(
        address asset
    ) external view override returns (uint16 value) {
        value = _s().debtStressRiseBps[asset];
    }

    /// @inheritdoc IParameterStoreLiquidation
    function aaveTargetHealthFactor(
        address spoke
    ) external view override returns (uint256 value) {
        value = _s().targetHealthFactor[spoke];
    }

    /// @inheritdoc IParameterStoreLiquidation
    function minLiquidationBonus(
        address spoke
    ) external view override returns (uint16 value) {
        value = _s().minLiquidationBonus[spoke];
    }

    /// @inheritdoc IParameterStoreBreakers
    function breakerDeficitMax(
        address hub,
        address asset
    ) external view override returns (uint256 value) {
        value = _s().breakerDeficitMax[hub][asset];
    }

    /// @inheritdoc IParameterStoreBreakers
    function gateRecoverySeconds() external view override returns (uint64 value) {
        value = _s().g.gateRecoverySeconds;
    }

    /// @inheritdoc IParameterStoreChain
    function sequencer() external view override returns (address feed, uint32 gracePeriod) {
        (feed, gracePeriod) = (_s().sequencer.feed, _s().sequencer.gracePeriod);
    }

    /// @inheritdoc IParameterStoreChain
    function CHAIN_BLOCK_TIME() external view override returns (uint32 value) {
        value = _BLOCK_TIME;
    }

    /// @inheritdoc IParameterStoreChain
    function twapMinObservations(
        uint256 marketId
    ) external view override returns (uint16 count) {
        count = _twapMinObservations(_s().market[marketId].twapWindow);
    }

    /// @inheritdoc IParameterStoreChain
    function heartbeatMargin(
        address feed
    ) external view override returns (uint32 margin) {
        margin = _s().feeds[feed].heartbeatMargin;
    }

    /// @inheritdoc IParameterStoreCoverage
    function coverageRatioBps() external view override returns (uint16 value) {
        value = _s().coverageRatioBps;
    }

    /// @inheritdoc IParameterStoreBreakers
    function tightenGateRecoverySeconds(
        uint64
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreBreakers
    function loosenGateRecoverySeconds(
        uint64
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreBreakers
    function tightenBreakerDeficitMax(
        address,
        address,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreBreakers
    function loosenBreakerDeficitMax(
        address,
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLiquidation
    function tightenMaxShortfallBps(
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLiquidation
    function loosenMaxShortfallBps(
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLiquidation
    function tightenDebtStressRiseBps(
        address,
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLiquidation
    function loosenDebtStressRiseBps(
        address,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLiquidation
    function setLiquidationExpectations(
        address,
        uint256,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStoreChain
    function setSequencer(
        address,
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStoreCoverage
    function setCoverageRatioBps(
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @dev Only `APPLICATION_ADMIN` (the timelock) upgrades, at the normal delay.
    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}
}
