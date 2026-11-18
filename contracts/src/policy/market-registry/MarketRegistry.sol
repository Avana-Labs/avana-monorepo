// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {MarketDef} from "../../types/MarketDef.sol";
import {PauseReason} from "../../types/PauseReason.sol";
import {RouteSlot} from "../../types/RouteSlot.sol";
import {IMarketRegistry} from "./IMarketRegistry.sol";
import {IMarketRegistryApprovals} from "./IMarketRegistryApprovals.sol";
import {IMarketRegistryBreakers} from "./IMarketRegistryBreakers.sol";
import {IMarketRegistryCreditLines} from "./IMarketRegistryCreditLines.sol";
import {IMarketRegistryFreeze} from "./IMarketRegistryFreeze.sol";
import {IMarketRegistryHubs} from "./IMarketRegistryHubs.sol";
import {IMarketRegistryListing} from "./IMarketRegistryListing.sol";
import {IMarketRegistryPause} from "./IMarketRegistryPause.sol";
import {IMarketRegistryRoutes} from "./IMarketRegistryRoutes.sol";
import {IMarketRegistryStandby} from "./IMarketRegistryStandby.sol";
import {IMarketRegistryWindDown} from "./IMarketRegistryWindDown.sol";
import {MarketRegistryRouter} from "./MarketRegistryRouter.sol";
import {DebtReserveDef} from "./types/DebtReserveDef.sol";
import {MarketRegistryImmutables} from "./types/MarketRegistryImmutables.sol";
import {MarketRegistryLogics} from "./types/MarketRegistryLogics.sol";
import {RiskTier} from "./types/RiskTier.sol";
import {SpokeDef} from "./types/SpokeDef.sol";
import {TokenDef} from "./types/TokenDef.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title MarketRegistry
/// @notice The chain's registry of Hubs, integrations, CDP Spokes, debt reserves, markets, routes, pause state, address
/// freeze and breakers.
/// @dev UUPS proxy; only the timelock can upgrade it. Write bodies run in logic contracts by delegatecall.
contract MarketRegistry is UUPSUpgradeable, MarketRegistryRouter, IMarketRegistry {
    /// @notice Fixes the implementation immutables and the six logic contracts; see `MarketRegistryRouter`.
    /// @param logics The six logic contracts, each built with `im`.
    constructor(
        MarketRegistryImmutables memory im,
        MarketRegistryLogics memory logics
    ) MarketRegistryRouter(im, logics) {}

    /// @inheritdoc IMarketRegistryListing
    function initialize(
        address timelock
    ) external override initializer {
        if (timelock != _TIMELOCK) revert AdminRoleOnlyTimelock(DEFAULT_ADMIN_ROLE, timelock);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _setRoleAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, AvanaRoles.APPLICATION_ADMIN);
        _setRoleAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN, AvanaRoles.APPLICATION_ADMIN);
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        _grantRole(AvanaRoles.APPLICATION_ADMIN, timelock);
    }

    /// @inheritdoc IMarketRegistryHubs
    function recordHub(
        address,
        RiskTier
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryHubs
    function registerIntegration(
        uint32,
        address,
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryHubs
    function setAvanaFirstLossReserve(
        address,
        address,
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryHubs
    function setCrossHubLine(
        address,
        address,
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryHubs
    function setCrossHubLinesEnabled(
        bool
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryHubs
    function setFlashSource(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryApprovals
    function approveSpokeCodeHash(
        bytes32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryApprovals
    function recordIntegrationContracts(
        uint32,
        address[] calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistryApprovals
    function finalizeIntegrationContracts(
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistryListing
    function deployCdpSpoke(
        SpokeDef calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) returns (address spoke) {
        spoke = abi.decode(_forwardReturning(_HUBS_LOGIC), (address));
    }

    /// @inheritdoc IMarketRegistryListing
    function enableDebtReserve(
        address,
        DebtReserveDef calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryListing
    function removeDebtReserve(
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryListing
    function listToken(
        address,
        TokenDef calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IMarketRegistryListing
    function setPriceSource(
        address,
        address[] calldata,
        address[] calldata,
        address[] calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IMarketRegistryListing
    function listCollateralMarket(
        MarketDef calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) returns (uint256 marketId) {
        marketId = abi.decode(_forwardReturning(_LISTING_LOGIC), (uint256));
    }

    /// @inheritdoc IMarketRegistryListing
    function activateMarket(
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ACTIVATION_LOGIC);
    }

    /// @inheritdoc IMarketRegistryListing
    function cancelRegistration(
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ACTIVATION_LOGIC);
    }

    /// @inheritdoc IMarketRegistryListing
    function setMarketOffboarding(
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ACTIVATION_LOGIC);
    }

    /// @inheritdoc IMarketRegistryRoutes
    function setRoute(
        uint256,
        address,
        address,
        uint8,
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistryRoutes
    function disableRoute(
        uint256,
        address,
        address,
        uint8
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistryRoutes
    function restoreRoute(
        uint256,
        address,
        address,
        uint8,
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistryStandby
    function useStandbyRoute(
        address token,
        RouteSlot
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        // A guardian waits out the lock after an Aave DAO cancel; the timelock does not.
        if (!hasRole(AvanaRoles.APPLICATION_ADMIN, msg.sender)) {
            uint64 at = _s().standbyCancelledAt[token];
            uint256 until = uint256(at) + _STANDBY_RESWITCH_COOLDOWN;
            if (at != 0 && block.timestamp < until) revert StandbySwitchLocked(token, until);
        }
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistryStandby
    function cancelStandbySwitch(
        address
    ) external override {
        if (msg.sender != _AAVE_GOVERNANCE_EXECUTOR) revert Unauthorized(msg.sender);
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistryStandby
    function restorePriceRoute(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistryPause
    function freeze(
        address
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryPause
    function pause(
        address,
        PauseReason
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryPause
    function freezeAll() external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryPause
    function pauseAll(
        PauseReason
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryPause
    function unfreeze(
        address
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryPause
    function unpause(
        address
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryFreeze
    function freezeAddress(
        address
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryFreeze
    function unfreezeAddress(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryBreakers
    function recordBreach(
        bytes32,
        uint32
    ) external override {
        if (msg.sender != _RISK_MODULE) revert NotRiskModule();
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryBreakers
    function tripMarketBreaker(
        uint256
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryBreakers
    function tripDebtBreaker(
        address,
        uint256
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryBreakers
    function resetMarketBreaker(
        uint256
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryBreakers
    function resetDebtBreaker(
        address,
        uint256
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryWindDown
    function closeMarket(
        uint256
    ) external override {
        _forward(_WIND_DOWN_LOGIC);
    }

    /// @inheritdoc IMarketRegistryWindDown
    function setSettlementReserve(
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_WIND_DOWN_LOGIC);
    }

    /// @inheritdoc IMarketRegistryCreditLines
    function recordCreditLine(
        address,
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_WIND_DOWN_LOGIC);
    }

    /// @inheritdoc IMarketRegistryCreditLines
    function syncDrawCap(
        address,
        uint256
    ) external override {
        _forward(_WIND_DOWN_LOGIC);
    }

    /// @dev Upgrades need `APPLICATION_ADMIN`, held only by the timelock.
    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}
}
