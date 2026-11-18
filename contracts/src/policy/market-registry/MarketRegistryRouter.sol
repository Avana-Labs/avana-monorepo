// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {IMarketRegistryLogic} from "./IMarketRegistryLogic.sol";
import {IMarketRegistryViews} from "./IMarketRegistryViews.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {MarketRegistryViews} from "./MarketRegistryViews.sol";
import {MarketRegistryImmutables} from "./types/MarketRegistryImmutables.sol";
import {MarketRegistryLogics} from "./types/MarketRegistryLogics.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title MarketRegistryRouter
/// @notice Roles of the MarketRegistry, its immutable getters and the dispatch of its writes to the logic contracts.
/// @dev Both admin roles can be held only by `TIMELOCK`. Each write checks its caller, then delegatecalls its logic.
abstract contract MarketRegistryRouter is AccessControlUpgradeable, MarketRegistryViews {
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

    /// @inheritdoc IMarketRegistryViews
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc IMarketRegistryViews
    function PROXY_MANAGER() external view override returns (address proxyManager) {
        proxyManager = _PROXY_MANAGER;
    }

    /// @inheritdoc IMarketRegistryViews
    function PARAMETER_STORE() external view override returns (address parameterStore) {
        parameterStore = _PARAMETER_STORE;
    }

    /// @inheritdoc IMarketRegistryViews
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc IMarketRegistryViews
    function VAULT_TOKEN_FACTORY() external view override returns (address factory) {
        factory = _VAULT_TOKEN_FACTORY;
    }

    /// @inheritdoc IMarketRegistryViews
    function RISK_MODULE() external view override returns (address riskModule) {
        riskModule = _RISK_MODULE;
    }

    /// @inheritdoc IMarketRegistryViews
    function AAVE_ADAPTER() external view override returns (address adapter) {
        adapter = _AAVE_ADAPTER;
    }

    /// @inheritdoc IMarketRegistryViews
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _TIMELOCK;
    }

    /// @inheritdoc IMarketRegistryViews
    function AAVE_GOVERNANCE_EXECUTOR() external view override returns (address executor) {
        executor = _AAVE_GOVERNANCE_EXECUTOR;
    }

    /// @inheritdoc IMarketRegistryViews
    function flashSource() external view override returns (address source) {
        source = _s().flashSource;
    }

    /// @inheritdoc IMarketRegistryViews
    function LOCK() external view override returns (address lock) {
        lock = _LOCK;
    }

    /// @inheritdoc IMarketRegistryViews
    function PAYOUT_ESCROW() external view override returns (address escrow) {
        escrow = _PAYOUT_ESCROW;
    }

    /// @inheritdoc IMarketRegistryViews
    function FLASH_LIQUIDATOR() external view override returns (address helper) {
        helper = _FLASH_LIQUIDATOR;
    }

    /// @inheritdoc IMarketRegistryViews
    function STANDARD_SPOKE_IMPLEMENTATION() external view override returns (address implementation) {
        implementation = _STANDARD_SPOKE_IMPLEMENTATION;
    }

    /// @inheritdoc IMarketRegistryViews
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
}
