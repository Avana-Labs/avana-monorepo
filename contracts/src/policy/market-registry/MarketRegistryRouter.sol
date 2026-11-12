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
/// @notice Roles of the MarketRegistry, its implementation-immutable getters and the dispatch of its writes to the six
/// logic contracts.
/// @dev Roles are OpenZeppelin AccessControl: `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` can be held only by
/// `TIMELOCK` (`_grantRole` reverts `AdminRoleOnlyTimelock` for any other grantee); `APPLICATION_PAUSE_GUARDIAN` and
/// `APPLICATION_FREEZE_GUARDIAN` are administered by `APPLICATION_ADMIN`. Every write checks its caller here and then
/// delegatecalls its logic contract with the unchanged calldata; the logic addresses are implementation immutables
/// whose `logicConfig()` the constructor checks, so a new logic contract is part of a new implementation and waits the
/// normal delay of `upgradeToAndCall`.
/// @custom:spec REQ-CONFIG-001, REQ-CONFIG-002, REQ-CONFIG-005, REQ-MREG-004, REQ-MREG-005, REQ-ACCESS-153, Q-226, Q-259
abstract contract MarketRegistryRouter is AccessControlUpgradeable, MarketRegistryViews {
    /// @dev Hubs, integrations, Coverage Spokes, cross-Hub lines, the flash source, CDP Spokes and debt reserves.
    address internal immutable _HUBS_LOGIC;
    /// @dev Tokens, price sources and market listing.
    address internal immutable _LISTING_LOGIC;
    /// @dev Market activation, cancellation and offboarding.
    address internal immutable _ACTIVATION_LOGIC;
    /// @dev Swap routes, the AMM integration contract records and the standby switch.
    address internal immutable _ROUTES_LOGIC;
    /// @dev Pause state and reason, address freeze and breakers.
    address internal immutable _SAFETY_LOGIC;
    /// @dev Wind-down, close, settlement reserve and the credit-line registry.
    address internal immutable _WIND_DOWN_LOGIC;

    /// @notice Fixes the implementation immutables, checks each logic contract and disables initializers on the
    /// implementation itself.
    /// @param im The per-chain Avana addresses.
    /// @param logics The six logic contracts, each built with `im`.
    /// @custom:spec REQ-CONFIG-002, REQ-CONFIG-005
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
    /// @custom:spec REQ-CONFIG-005
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-005
    function PROXY_MANAGER() external view override returns (address proxyManager) {
        proxyManager = _PROXY_MANAGER;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-005
    function PARAMETER_STORE() external view override returns (address parameterStore) {
        parameterStore = _PARAMETER_STORE;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-005
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-005
    function VAULT_TOKEN_FACTORY() external view override returns (address factory) {
        factory = _VAULT_TOKEN_FACTORY;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-005
    function RISK_MODULE() external view override returns (address riskModule) {
        riskModule = _RISK_MODULE;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-005
    function AAVE_ADAPTER() external view override returns (address adapter) {
        adapter = _AAVE_ADAPTER;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-005, REQ-MREG-005
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _TIMELOCK;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-005, REQ-MREG-028
    function AAVE_GOVERNANCE_EXECUTOR() external view override returns (address executor) {
        executor = _AAVE_GOVERNANCE_EXECUTOR;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-005, REQ-MREG-020
    function flashSource() external view override returns (address source) {
        source = _s().flashSource;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-005
    function LOCK() external view override returns (address lock) {
        lock = _LOCK;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-005
    function PAYOUT_ESCROW() external view override returns (address escrow) {
        escrow = _PAYOUT_ESCROW;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-005, REQ-MREG-020, REQ-HELPER-010
    function FLASH_LIQUIDATOR() external view override returns (address helper) {
        helper = _FLASH_LIQUIDATOR;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-005, REQ-CONFIG-074
    function STANDARD_SPOKE_IMPLEMENTATION() external view override returns (address implementation) {
        implementation = _STANDARD_SPOKE_IMPLEMENTATION;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-MREG-034
    function MAX_MARKET_COUNT() external view override returns (uint256 limit) {
        limit = _MAX_MARKET_COUNT;
    }

    /// @dev The activation logic serves the per-market reads of `spokeSettingsDrift`.
    function _driftLogic() internal view override returns (address) {
        return _ACTIVATION_LOGIC;
    }

    /// @dev Either admin role can be held only by `TIMELOCK`, through `initialize` or any later grant.
    /// @custom:spec REQ-MREG-005, REQ-ACCESS-153, Q-259
    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        if ((role == DEFAULT_ADMIN_ROLE || role == AvanaRoles.APPLICATION_ADMIN) && account != _TIMELOCK) {
            revert AdminRoleOnlyTimelock(role, account);
        }
        granted = super._grantRole(role, account);
    }

    /// @dev `Unauthorized(msg.sender)` unless the caller holds `guardianRole` or `APPLICATION_ADMIN` (REQ-MREG-004).
    function _onlyGuardianOrAdmin(
        bytes32 guardianRole
    ) internal view {
        if (!hasRole(guardianRole, msg.sender) && !hasRole(AvanaRoles.APPLICATION_ADMIN, msg.sender)) {
            revert Unauthorized(msg.sender);
        }
    }

    /// @dev Runs the current call's body in `logic`, in this contract's storage; reverts bubble up unchanged. For a
    /// write that returns nothing the logic's return data is empty and is not read.
    function _forward(
        address logic
    ) internal {
        _forwardReturning(logic);
    }

    /// @dev As `_forward`, returning the logic's return data for the writes that return a value.
    function _forwardReturning(
        address logic
    ) internal returns (bytes memory ret) {
        ret = Address.functionDelegateCall(logic, msg.data);
    }

    /// @dev Reverts unless `logic` reports `kind` and the same implementation immutables.
    function _requireLogic(
        address logic,
        bytes32 kind
    ) private view {
        (bytes32 k, bytes32 h) = IMarketRegistryLogic(logic).logicConfig();
        if (k != kind || h != _IMMUTABLES_HASH) revert ListingCheckFailed("logic");
    }
}
