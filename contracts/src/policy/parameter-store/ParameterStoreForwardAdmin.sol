// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {IParameterStoreAdmin} from "./IParameterStoreAdmin.sol";
import {IParameterStoreListing} from "./IParameterStoreListing.sol";
import {ParameterStoreRouter} from "./ParameterStoreRouter.sol";
import {DebtReserveParams} from "./types/DebtReserveParams.sol";
import {FeedDef} from "./types/FeedDef.sol";
import {MarketParams} from "./types/MarketParams.sol";

/// @title ParameterStoreForwardAdmin
/// @notice The structural and listing setters; `initialize` is in the ParameterStore itself.
/// @dev Each function checks the caller's role and delegatecalls the logic contract that holds its body with the
/// unchanged calldata (`ParameterStoreRouter._forward`).
/// @custom:spec REQ-PSTORE-002, REQ-CONFIG-054, REQ-PSTORE-029
abstract contract ParameterStoreForwardAdmin is ParameterStoreRouter, IParameterStoreAdmin, IParameterStoreListing {
    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-023, REQ-CONFIG-049, REQ-CONFIG-054, REQ-PSTORE-009, SPEC-ORC-019, Q-322
    function setBorrowPriceMaxAge(
        address,
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-049, REQ-CONFIG-052, REQ-CONFIG-054
    function setConsistencyToleranceBps(
        uint256,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-024, REQ-CONFIG-049, REQ-CONFIG-054
    function setFeedAgreementToleranceBps(
        address,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-015, REQ-CONFIG-049, REQ-CONFIG-054
    function setPoolRiskFactor(
        uint256,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-049, REQ-PSTORE-010, Q-097
    function setAvanaFeeShareBps(
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-056
    function setFeeRecipient(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-049, REQ-PSTORE-021, REQ-PSTORE-024, Q-135, Q-261, Q-335
    function setMaxFlashFeeBps(
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-049, REQ-PSTORE-024, Q-335
    function tightenMaxFlashFeeBps(
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-PSTORE-028, REQ-PSTORE-029, REQ-PSTORE-009, REQ-ORACLE-100, SPEC-ORC-020, Q-323
    function setSecondSource(
        address,
        SecondSource calldata,
        SecondSource calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-PSTORE-029, EMG-103
    function useStandbySecondSource(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN) {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-PSTORE-029, EMG-103
    function restoreSecondSource(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-049, Q-183
    function setCachedWindow(
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-052, Q-183
    function setDisagreementPauseMax(
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-038, REQ-CONFIG-054
    function setTwapWindow(
        uint256,
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-054, REQ-CONFIG-055, Q-176, Q-195, Q-246
    function setUsdBand(
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-023, REQ-CONFIG-052
    function setLiquidationPriceMaxAge(
        address,
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-023, REQ-CONFIG-049, REQ-CONFIG-054, REQ-ORACLE-002
    function setFeedMaxAge(
        address,
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-052, Q-246
    function setGraceDuration(
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-052, Q-246
    function setGraceHealthFactor(
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-024, REQ-CONFIG-049
    function setFeedAgreementMarginBps(
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-041, REQ-CONFIG-049, REQ-PSTORE-021, Q-261
    function setSlippageAllowanceMinBps(
        uint256,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_ORACLE_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-CONFIG-019, REQ-CONFIG-020, REQ-CONFIG-049
    function setTokenCollateralFactorBps(
        address,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStoreAdmin
    /// @custom:spec REQ-RISK-045, SPEC-CAP-006
    function setStressFloorUsd(
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStoreListing
    /// @custom:spec REQ-PSTORE-004, REQ-PSTORE-005, REQ-PSTORE-012, REQ-CONFIG-015, REQ-CONFIG-036, REQ-CONFIG-038, REQ-CONFIG-041
    function setInitialMarketParams(
        uint256,
        MarketParams calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStoreListing
    /// @custom:spec REQ-RISK-041, REQ-PSTORE-012
    function setInitialMarketCaps(
        uint256,
        uint256,
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStoreListing
    /// @custom:spec REQ-PSTORE-026
    function setInitialHubCaps(
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStoreListing
    /// @custom:spec REQ-RISK-041, REQ-PSTORE-012, REQ-PSTORE-026
    function setInitialTokenCap(
        address,
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStoreListing
    /// @custom:spec REQ-CONFIG-022, REQ-CONFIG-023, REQ-CONFIG-024, REQ-PSTORE-009, REQ-PSTORE-013, SPEC-ORC-019, Q-322
    function setFeed(
        address,
        FeedDef calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStoreListing
    /// @custom:spec REQ-PSTORE-006, REQ-CONFIG-050, Q-380
    function setDebtAssetParams(
        address,
        DebtReserveParams calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }
}
