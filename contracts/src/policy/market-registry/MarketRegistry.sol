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
/// @notice The chain's record of Hubs, AMM integrations, CDP Spokes and their debt reserves, markets and their
/// status, listed tokens with their price routes, swap routes, each Hub's pause state, the address freeze and the
/// breaker latches.
/// @dev UUPS implementation behind one fixed ERC-1967 proxy; `_authorizeUpgrade` requires `APPLICATION_ADMIN`, held
/// only by the timelock. It serves every view and checks every write's caller itself; each write body runs in one of
/// six immutable logic contracts by delegatecall (`MarketRegistryRouter`), because the whole surface does not fit the
/// 24,576-byte code limit in one contract. All state is in the ERC-7201 namespace `avana.storage.MarketRegistry`. The
/// registry holds no token, and besides those delegatecalls makes only view calls and the integration's `bindMarket`.
/// @custom:spec REQ-CONFIG-001, REQ-CONFIG-002, REQ-CONFIG-003, REQ-CONFIG-004, REQ-CONFIG-005, REQ-CONFIG-014, REQ-CONFIG-028, REQ-CONFIG-064, REQ-CONFIG-069, REQ-MREG-004, REQ-MREG-005, REQ-MREG-011, REQ-MREG-013, REQ-MREG-016, REQ-MREG-029, Q-226, Q-227, Q-228, Q-259, Q-401
contract MarketRegistry is UUPSUpgradeable, MarketRegistryRouter, IMarketRegistry {
    /// @notice Fixes the implementation immutables and the six logic contracts; see `MarketRegistryRouter`.
    /// @param im The per-chain Avana addresses.
    /// @param logics The six logic contracts, each built with `im`.
    /// @custom:spec REQ-CONFIG-002, REQ-CONFIG-005
    constructor(
        MarketRegistryImmutables memory im,
        MarketRegistryLogics memory logics
    ) MarketRegistryRouter(im, logics) {}

    /// @inheritdoc IMarketRegistryListing
    /// @custom:spec REQ-CONFIG-002, REQ-MREG-005, Q-259
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

    // ---------------------------------------------------------------------------------------------------------------
    // Hubs, integrations, Spokes and debt reserves (APPLICATION_ADMIN, normal delay)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec REQ-CONFIG-083, Q-378, Q-388
    function recordHub(
        address,
        RiskTier
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec REQ-CONFIG-075, Q-376
    function registerIntegration(
        uint32,
        address,
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec REQ-MREG-009, Q-379
    function setCoverageSpoke(
        address,
        address,
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec Q-378
    function setCrossHubLine(
        address,
        address,
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec REQ-CONFIG-081, Q-378
    function setCrossHubLinesEnabled(
        bool
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec REQ-CONFIG-005, INV-095, Q-386
    function setFlashSource(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryApprovals
    /// @custom:spec REQ-CONFIG-074
    function approveSpokeCodeHash(
        bytes32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryApprovals
    /// @custom:spec REQ-MREG-020, REQ-CONFIG-040
    function recordIntegrationContracts(
        uint32,
        address[] calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryListing
    /// @custom:spec REQ-CONFIG-077, REQ-CONFIG-074, REQ-CONFIG-016
    function deployCdpSpoke(
        SpokeDef calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) returns (address spoke) {
        spoke = abi.decode(_forwardReturning(_HUBS_LOGIC), (address));
    }

    /// @inheritdoc IMarketRegistryListing
    /// @custom:spec REQ-MREG-006, REQ-CONFIG-079
    function enableDebtReserve(
        address,
        DebtReserveDef calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistryListing
    /// @custom:spec REQ-MREG-010
    function removeDebtReserve(
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Tokens and markets
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IMarketRegistryListing
    /// @custom:spec REQ-CONFIG-017, REQ-CONFIG-026, REQ-MREG-027
    function listToken(
        address,
        TokenDef calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IMarketRegistryListing
    /// @custom:spec REQ-CONFIG-026, REQ-CONFIG-027
    function setPriceSource(
        address,
        address[] calldata,
        address[] calldata,
        address[] calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IMarketRegistryListing
    /// @custom:spec REQ-CONFIG-028, REQ-CONFIG-078
    function listCollateralMarket(
        MarketDef calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) returns (uint256 marketId) {
        marketId = abi.decode(_forwardReturning(_LISTING_LOGIC), (uint256));
    }

    /// @inheritdoc IMarketRegistryListing
    /// @custom:spec REQ-CONFIG-042, REQ-CONFIG-073
    function activateMarket(
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ACTIVATION_LOGIC);
    }

    /// @inheritdoc IMarketRegistryListing
    /// @custom:spec REQ-CONFIG-048
    function cancelRegistration(
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ACTIVATION_LOGIC);
    }

    /// @inheritdoc IMarketRegistryListing
    /// @custom:spec REQ-MREG-015
    function setMarketOffboarding(
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ACTIVATION_LOGIC);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Swap routes and the standby switch
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IMarketRegistryRoutes
    /// @custom:spec REQ-CONFIG-060
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
    /// @custom:spec REQ-CONFIG-061
    function disableRoute(
        uint256,
        address,
        address,
        uint8
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistryRoutes
    /// @custom:spec REQ-CONFIG-062
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
    /// @custom:spec REQ-MREG-028
    function useStandbyRoute(
        address token,
        RouteSlot
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        // A guardian waits out the Aave DAO's cancel of the token's last switch; the timelock's own call does not.
        if (!hasRole(AvanaRoles.APPLICATION_ADMIN, msg.sender)) {
            uint64 at = _s().standbyCancelledAt[token];
            uint256 until = uint256(at) + _STANDBY_RESWITCH_COOLDOWN;
            if (at != 0 && block.timestamp < until) revert StandbySwitchLocked(token, until);
        }
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistryStandby
    /// @custom:spec REQ-MREG-028
    function cancelStandbySwitch(
        address
    ) external override {
        if (msg.sender != _AAVE_GOVERNANCE_EXECUTOR) revert Unauthorized(msg.sender);
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistryStandby
    /// @custom:spec REQ-MREG-028
    function restorePriceRoute(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ROUTES_LOGIC);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Pause state, address freeze and breakers
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IMarketRegistryPause
    /// @custom:spec REQ-MREG-001, REQ-MREG-004
    function freeze(
        address
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryPause
    /// @custom:spec REQ-MREG-001, REQ-MREG-004, REQ-MREG-024
    function pause(
        address,
        PauseReason
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryPause
    /// @custom:spec REQ-CONFIG-082, REQ-MREG-004
    function freezeAll() external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryPause
    /// @custom:spec REQ-CONFIG-082, REQ-MREG-004
    function pauseAll(
        PauseReason
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryPause
    /// @custom:spec REQ-MREG-001, REQ-MREG-004
    function unfreeze(
        address
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryPause
    /// @custom:spec REQ-MREG-001, REQ-MREG-004, REQ-MREG-024
    function unpause(
        address
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryFreeze
    /// @custom:spec REQ-MREG-019
    function freezeAddress(
        address
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryFreeze
    /// @custom:spec REQ-MREG-022
    function unfreezeAddress(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryBreakers
    /// @custom:spec REQ-MREG-026
    function recordBreach(
        bytes32,
        uint32
    ) external override {
        if (msg.sender != _RISK_MODULE) revert NotRiskModule();
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryBreakers
    /// @custom:spec REQ-MREG-025
    function tripMarketBreaker(
        uint256
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryBreakers
    /// @custom:spec REQ-MREG-025
    function tripDebtBreaker(
        address,
        uint256
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryBreakers
    /// @custom:spec REQ-MREG-025
    function resetMarketBreaker(
        uint256
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistryBreakers
    /// @custom:spec REQ-MREG-025
    function resetDebtBreaker(
        address,
        uint256
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Wind-down, settlement reserve and the credit-line registry
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IMarketRegistryWindDown
    /// @custom:spec REQ-CONFIG-080
    function stepWindDown(
        uint256
    ) external override {
        _forward(_WIND_DOWN_LOGIC);
    }

    /// @inheritdoc IMarketRegistryWindDown
    /// @custom:spec REQ-CONFIG-080
    function closeMarket(
        uint256
    ) external override {
        _forward(_WIND_DOWN_LOGIC);
    }

    /// @inheritdoc IMarketRegistryWindDown
    /// @custom:spec REQ-MREG-033
    function setSettlementReserve(
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_WIND_DOWN_LOGIC);
    }

    /// @inheritdoc IMarketRegistryCreditLines
    /// @custom:spec REQ-CONFIG-081
    function recordCreditLine(
        address,
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_WIND_DOWN_LOGIC);
    }

    /// @inheritdoc IMarketRegistryCreditLines
    /// @custom:spec REQ-CONFIG-081
    function syncDrawCap(
        address,
        uint256
    ) external override {
        _forward(_WIND_DOWN_LOGIC);
    }

    /// @dev Upgrades need `APPLICATION_ADMIN`, held only by the timelock (normal delay).
    /// @custom:spec REQ-CONFIG-001, REQ-CONFIG-002
    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}
}
