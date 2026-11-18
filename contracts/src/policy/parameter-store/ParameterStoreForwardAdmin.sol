// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {IParameterStore} from "./IParameterStore.sol";
import {IParameterStoreListing} from "./IParameterStoreListing.sol";
import {ParameterStoreRouter} from "./ParameterStoreRouter.sol";
import {DebtReserveParams, FeedDef, MarketParams} from "./types/ParameterStoreTypes.sol";

/// @title ParameterStoreForwardAdmin
/// @notice The structural and listing setters; `initialize` is in the ParameterStore itself.
abstract contract ParameterStoreForwardAdmin is ParameterStoreRouter, IParameterStore {
    /// @inheritdoc IParameterStore
    function setBorrowPriceMaxAge(
        address,
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setConsistencyToleranceBps(
        uint256,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setFeedAgreementToleranceBps(
        address,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setPoolRiskFactor(
        uint256,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setAvanaFeeShareBps(
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setFeeRecipient(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setMaxFlashFeeBps(
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function tightenMaxFlashFeeBps(
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setSecondSource(
        address,
        SecondSource calldata,
        SecondSource calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function useStandbySecondSource(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN) {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function restoreSecondSource(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setCachedWindow(
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setDisagreementPauseMax(
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setTwapWindow(
        uint256,
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setUsdBand(
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setLiquidationPriceMaxAge(
        address,
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setFeedMaxAge(
        address,
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setGraceDuration(
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setGraceHealthFactor(
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setFeedAgreementMarginBps(
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setSlippageAllowanceMinBps(
        uint256,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setTokenCollateralFactorBps(
        address,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setStressFloorUsd(
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStoreListing
    function setInitialMarketParams(
        uint256,
        MarketParams calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStoreListing
    function setInitialMarketCaps(
        uint256,
        uint256,
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStoreListing
    function setInitialTokenCap(
        address,
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStoreListing
    function setFeed(
        address,
        FeedDef calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStoreListing
    function setDebtAssetParams(
        address,
        DebtReserveParams calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }
}
