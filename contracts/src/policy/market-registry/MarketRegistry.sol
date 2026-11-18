// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {MarketDef, PauseReason} from "../../types/MarketTypes.sol";
import {RouteSlot} from "../../types/OracleTypes.sol";
import {IMarketRegistry} from "./IMarketRegistry.sol";
import {IMarketRegistryLogic} from "./IMarketRegistryLogic.sol";
import {IMarketRegistryRoutes} from "./IMarketRegistryRoutes.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {MarketRegistryViews} from "./MarketRegistryViews.sol";
import {
    DebtReserveDef,
    MarketRegistryImmutables,
    MarketRegistryLogics,
    RiskTier,
    SpokeDef,
    TokenDef
} from "./types/MarketRegistryTypes.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title MarketRegistry
/// @notice The chain's registry of Hubs, integrations, CDP Spokes, debt reserves, markets, routes, pause state, address
/// freeze and breakers.
/// @dev UUPS proxy; only the timelock can upgrade it. Write bodies run in logic contracts by delegatecall.
contract MarketRegistry is UUPSUpgradeable, AccessControlUpgradeable, MarketRegistryViews {
    address internal immutable _HUBS_LOGIC;
    address internal immutable _LISTING_LOGIC;
    address internal immutable _ACTIVATION_LOGIC;
    address internal immutable _ROUTES_LOGIC;
    address internal immutable _SAFETY_LOGIC;
    address internal immutable _WIND_DOWN_LOGIC;

    constructor(
        MarketRegistryImmutables memory im,
        MarketRegistryLogics memory logics
    ) MarketRegistryStorage(im) {
        _requireLogic(logics.hubs, keccak256("MarketRegistryHubsLogic"));
        _requireLogic(logics.listing, keccak256("MarketRegistryListingLogic"));
        _requireLogic(logics.activation, keccak256("MarketRegistryActivationLogic"));
        _requireLogic(logics.routes, keccak256("MarketRegistryRoutesLogic"));
        _requireLogic(logics.safety, keccak256("MarketRegistrySafetyLogic"));
        _requireLogic(logics.windDown, keccak256("MarketRegistryWindDownLogic"));
        _HUBS_LOGIC = logics.hubs;
        _LISTING_LOGIC = logics.listing;
        _ACTIVATION_LOGIC = logics.activation;
        _ROUTES_LOGIC = logics.routes;
        _SAFETY_LOGIC = logics.safety;
        _WIND_DOWN_LOGIC = logics.windDown;
        _disableInitializers();
    }

    /// @inheritdoc IMarketRegistry
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc IMarketRegistry
    function PROXY_MANAGER() external view override returns (address proxyManager) {
        proxyManager = _PROXY_MANAGER;
    }

    /// @inheritdoc IMarketRegistry
    function PARAMETER_STORE() external view override returns (address parameterStore) {
        parameterStore = _PARAMETER_STORE;
    }

    /// @inheritdoc IMarketRegistry
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc IMarketRegistry
    function VAULT_TOKEN_FACTORY() external view override returns (address factory) {
        factory = _VAULT_TOKEN_FACTORY;
    }

    /// @inheritdoc IMarketRegistry
    function RISK_MODULE() external view override returns (address riskModule) {
        riskModule = _RISK_MODULE;
    }

    /// @inheritdoc IMarketRegistry
    function AAVE_ADAPTER() external view override returns (address adapter) {
        adapter = _AAVE_ADAPTER;
    }

    /// @inheritdoc IMarketRegistry
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _TIMELOCK;
    }

    /// @inheritdoc IMarketRegistry
    function AAVE_GOVERNANCE_EXECUTOR() external view override returns (address executor) {
        executor = _AAVE_GOVERNANCE_EXECUTOR;
    }

    /// @inheritdoc IMarketRegistry
    function flashSource() external view override returns (address source) {
        source = _s().flashSource;
    }

    /// @inheritdoc IMarketRegistry
    function LOCK() external view override returns (address lock) {
        lock = _LOCK;
    }

    /// @inheritdoc IMarketRegistry
    function PAYOUT_ESCROW() external view override returns (address escrow) {
        escrow = _PAYOUT_ESCROW;
    }

    /// @inheritdoc IMarketRegistry
    function FLASH_LIQUIDATOR() external view override returns (address helper) {
        helper = _FLASH_LIQUIDATOR;
    }

    /// @inheritdoc IMarketRegistry
    function STANDARD_SPOKE_IMPLEMENTATION() external view override returns (address implementation) {
        implementation = _STANDARD_SPOKE_IMPLEMENTATION;
    }

    /// @inheritdoc IMarketRegistry
    function MAX_MARKET_COUNT() external view override returns (uint256 limit) {
        limit = _MAX_MARKET_COUNT;
    }

    /// @dev The activation logic serves the per-market reads of `spokeSettingsDrift`.
    function _driftLogic() internal view override returns (address) {
        return _ACTIVATION_LOGIC;
    }

    /// @dev Either admin role can be held only by `TIMELOCK`, through `initialize` or any later grant.
    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        if ((role == DEFAULT_ADMIN_ROLE || role == AvanaRoles.APPLICATION_ADMIN) && account != _TIMELOCK) {
            revert AdminRoleOnlyTimelock(role, account);
        }
        granted = super._grantRole(role, account);
    }

    function _onlyGuardianOrAdmin(
        bytes32 guardianRole
    ) internal view {
        if (!hasRole(guardianRole, msg.sender) && !hasRole(AvanaRoles.APPLICATION_ADMIN, msg.sender)) {
            revert Unauthorized(msg.sender);
        }
    }

    /// @dev Delegatecalls `logic` with the current calldata; reverts bubble up unchanged.
    function _forward(
        address logic
    ) internal {
        _forwardReturning(logic);
    }

    function _forwardReturning(
        address logic
    ) internal returns (bytes memory ret) {
        ret = Address.functionDelegateCall(logic, msg.data);
    }

    function _requireLogic(
        address logic,
        bytes32 kind
    ) private view {
        (bytes32 k, bytes32 h) = IMarketRegistryLogic(logic).logicConfig();
        if (k != kind || h != _IMMUTABLES_HASH) revert ListingCheckFailed("logic");
    }

    /// @inheritdoc IMarketRegistry
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

    /// @inheritdoc IMarketRegistry
    function recordHub(
        address,
        RiskTier
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function registerIntegration(
        uint32,
        address,
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function setAvanaFirstLossReserve(
        address,
        address,
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function setCrossHubLine(
        address,
        address,
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function setCrossHubLinesEnabled(
        bool
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function setFlashSource(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function approveSpokeCodeHash(
        bytes32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function recordIntegrationContracts(
        uint32,
        address[] calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function finalizeIntegrationContracts(
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function deployCdpSpoke(
        SpokeDef calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) returns (address spoke) {
        spoke = abi.decode(_forwardReturning(_HUBS_LOGIC), (address));
    }

    /// @inheritdoc IMarketRegistry
    function enableDebtReserve(
        address,
        DebtReserveDef calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function removeDebtReserve(
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_HUBS_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function listToken(
        address,
        TokenDef calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function setPriceSource(
        address,
        address[] calldata,
        address[] calldata,
        address[] calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function listCollateralMarket(
        MarketDef calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) returns (uint256 marketId) {
        marketId = abi.decode(_forwardReturning(_LISTING_LOGIC), (uint256));
    }

    /// @inheritdoc IMarketRegistry
    function activateMarket(
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ACTIVATION_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function cancelRegistration(
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ACTIVATION_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
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

    /// @inheritdoc IMarketRegistry
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

    /// @inheritdoc IMarketRegistry
    function cancelStandbySwitch(
        address
    ) external override {
        if (msg.sender != _AAVE_GOVERNANCE_EXECUTOR) revert Unauthorized(msg.sender);
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function restorePriceRoute(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_ROUTES_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function freeze(
        address
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function pause(
        address,
        PauseReason
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function freezeAll() external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function pauseAll(
        PauseReason
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function unfreeze(
        address
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function unpause(
        address
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function freezeAddress(
        address
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function unfreezeAddress(
        address
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function recordBreach(
        bytes32,
        uint32
    ) external override {
        if (msg.sender != _RISK_MODULE) revert NotRiskModule();
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function tripMarketBreaker(
        uint256
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function tripDebtBreaker(
        address,
        uint256
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_FREEZE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function resetMarketBreaker(
        uint256
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function resetDebtBreaker(
        address,
        uint256
    ) external override {
        _onlyGuardianOrAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN);
        _forward(_SAFETY_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function closeMarket(
        uint256
    ) external override {
        _forward(_WIND_DOWN_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function setSettlementReserve(
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_WIND_DOWN_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
    function recordCreditLine(
        address,
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_WIND_DOWN_LOGIC);
    }

    /// @inheritdoc IMarketRegistry
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
