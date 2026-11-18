// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {IProxyManager} from "../../proxy/proxy-manager/IProxyManager.sol";
import {PositionRef} from "../../types/PositionRef.sol";
import {IMarketRegistry} from "../market-registry/IMarketRegistry.sol";
import {AaveAdapterStorage} from "./AaveAdapterStorage.sol";
import {IAaveAdapter} from "./IAaveAdapter.sol";
import {IAaveAdapterAdmin} from "./IAaveAdapterAdmin.sol";
import {IAaveAdapterCollateral} from "./IAaveAdapterCollateral.sol";
import {IAaveAdapterLogic} from "./IAaveAdapterLogic.sol";
import {IAaveAdapterSettlement} from "./IAaveAdapterSettlement.sol";
import {IAaveAdapterUser} from "./IAaveAdapterUser.sol";
import {IAaveAdapterViews} from "./IAaveAdapterViews.sol";
import {AaveAdapterImmutables} from "./types/AaveAdapterImmutables.sol";
import {AaveAdapterLogics} from "./types/AaveAdapterLogics.sol";
import {AdapterAccount} from "./types/AdapterAccount.sol";
import {RepayWithCollateralParams} from "./types/RepayWithCollateralParams.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title AaveAdapter
/// @notice The chain's single entry point for every borrower action; entry-point bodies live in four logic contracts.
/// @dev UUPS proxy; only the timelock can upgrade it.
contract AaveAdapter is IAaveAdapter, UUPSUpgradeable, AccessControlUpgradeable, AaveAdapterStorage {
    address internal immutable _USER_LOGIC;
    address internal immutable _EXIT_LOGIC;
    address internal immutable _COLLATERAL_LOGIC;
    address internal immutable _SETTLEMENT_LOGIC;

    constructor(
        AaveAdapterImmutables memory im,
        AaveAdapterLogics memory logics
    ) AaveAdapterStorage(im) {
        _requireLogic(logics.user, keccak256("AaveAdapterUserLogic"));
        _requireLogic(logics.exit, keccak256("AaveAdapterExitLogic"));
        _requireLogic(logics.collateral, keccak256("AaveAdapterCollateralLogic"));
        _requireLogic(logics.settlement, keccak256("AaveAdapterSettlementLogic"));
        _USER_LOGIC = logics.user;
        _EXIT_LOGIC = logics.exit;
        _COLLATERAL_LOGIC = logics.collateral;
        _SETTLEMENT_LOGIC = logics.settlement;
        _disableInitializers();
    }

    /// @inheritdoc IAaveAdapterAdmin
    function initialize(
        address timelock
    ) external override initializer {
        if (timelock == address(0)) revert ZeroAddress();
        if (timelock != _TIMELOCK) revert AdminRoleOnlyTimelock(DEFAULT_ADMIN_ROLE, timelock);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        _grantRole(AvanaRoles.APPLICATION_ADMIN, timelock);
    }

    /// @inheritdoc IAaveAdapterUser
    function pledge(
        uint256,
        PositionRef calldata,
        uint256
    ) external override returns (address proxy, uint256 recordId, uint128 credited) {
        (proxy, recordId, credited) = abi.decode(_forward(_USER_LOGIC), (address, uint256, uint128));
    }

    /// @inheritdoc IAaveAdapterUser
    function borrow(
        uint256,
        uint256,
        uint256,
        address,
        uint256,
        uint256,
        uint256
    ) external override returns (uint256 drawn) {
        drawn = abi.decode(_forward(_USER_LOGIC), (uint256));
    }

    /// @inheritdoc IAaveAdapterUser
    function repay(
        address,
        uint256,
        uint256,
        uint256,
        bool,
        uint256
    ) external override returns (uint256 spent) {
        spent = abi.decode(_forward(_USER_LOGIC), (uint256));
    }

    /// @inheritdoc IAaveAdapterUser
    function withdraw(
        uint256,
        PositionRef calldata,
        uint256,
        uint256,
        uint256
    ) external override {
        _forward(_EXIT_LOGIC);
    }

    /// @inheritdoc IAaveAdapterUser
    function repayAllAndWithdraw(
        uint256,
        PositionRef calldata,
        uint256,
        uint256[] calldata,
        uint256[] calldata,
        uint256
    ) external override {
        _forward(_EXIT_LOGIC);
    }

    /// @inheritdoc IAaveAdapterUser
    function releaseZeroCredit(
        uint256,
        PositionRef calldata,
        uint256
    ) external override {
        _forward(_EXIT_LOGIC);
    }

    /// @inheritdoc IAaveAdapterUser
    function collectFees(
        uint256,
        PositionRef calldata,
        uint256
    ) external override returns (uint256[] memory fees) {
        fees = abi.decode(_forward(_EXIT_LOGIC), (uint256[]));
    }

    /// @inheritdoc IAaveAdapterUser
    function refreshDebtMark(
        address
    ) external override {
        _forward(_EXIT_LOGIC);
    }

    /// @inheritdoc IAaveAdapterCollateral
    function removeLiquidity(
        uint256,
        PositionRef calldata,
        uint128,
        uint256[] calldata,
        uint256,
        uint256
    ) external override returns (uint256[] memory amounts) {
        amounts = abi.decode(_forward(_COLLATERAL_LOGIC), (uint256[]));
    }

    /// @inheritdoc IAaveAdapterCollateral
    function recredit(
        uint256,
        PositionRef calldata,
        bytes calldata,
        uint256
    ) external override returns (uint128 added) {
        added = abi.decode(_forward(_COLLATERAL_LOGIC), (uint128));
    }

    /// @inheritdoc IAaveAdapterCollateral
    function repayWithCollateral(
        RepayWithCollateralParams calldata
    ) external override returns (uint256 debtRepaid, uint256 debtAssetToWallet) {
        (debtRepaid, debtAssetToWallet) = abi.decode(_forward(_COLLATERAL_LOGIC), (uint256, uint256));
    }

    /// @inheritdoc IAaveAdapterSettlement
    function burnSeized(
        uint256,
        address,
        uint256
    ) external override {
        _forward(_SETTLEMENT_LOGIC);
    }

    /// @inheritdoc IAaveAdapterSettlement
    function deleverageRepay(
        address,
        uint256,
        uint256
    ) external override returns (uint256 repaid) {
        repaid = abi.decode(_forward(_SETTLEMENT_LOGIC), (uint256));
    }

    /// @inheritdoc IAaveAdapterSettlement
    function deleverageRelease(
        address,
        PositionRef calldata,
        uint128,
        uint256[] calldata
    ) external override returns (uint256[] memory amounts, bool closed) {
        (amounts, closed) = abi.decode(_forward(_SETTLEMENT_LOGIC), (uint256[], bool));
    }

    /// @inheritdoc IAaveAdapterViews
    function proxyOf(
        address wallet,
        uint256 marketId
    ) external view override returns (address proxy) {
        proxy = _s().proxyOf[wallet][marketId];
    }

    /// @inheritdoc IAaveAdapterViews
    function walletOf(
        address proxy
    ) external view override returns (address wallet) {
        wallet = _s().walletOf[proxy];
    }

    /// @inheritdoc IAaveAdapterViews
    function accountOf(
        address proxy
    ) external view override returns (address spoke, uint256 marketId, address vaultToken, uint256 reserveId) {
        AdapterAccount storage a = _s().accountOf[proxy];
        (spoke, marketId, vaultToken, reserveId) = (a.spoke, a.marketId, a.vaultToken, a.reserveId);
    }

    /// @inheritdoc IAaveAdapterViews
    function predictProxy(
        address wallet,
        uint256 marketId
    ) external view override returns (address proxy) {
        proxy = _s().proxyOf[wallet][marketId];
        if (proxy != address(0)) return proxy;
        address spoke = IMarketRegistry(_MARKET_REGISTRY).getMarket(marketId).spoke;
        proxy = IProxyManager(_PROXY_MANAGER).predictProxy(wallet, spoke, marketId);
    }

    /// @inheritdoc IAaveAdapterViews
    function borrowNonce(
        address proxy
    ) external view override returns (uint256 nonce) {
        nonce = _s().borrowNonce[proxy];
    }

    /// @inheritdoc IAaveAdapterViews
    function APPLICATION_ADMIN() external pure override returns (bytes32 role) {
        role = AvanaRoles.APPLICATION_ADMIN;
    }

    /// @inheritdoc IAaveAdapterViews
    function PROXY_MANAGER() external view override returns (address proxyManager) {
        proxyManager = _PROXY_MANAGER;
    }

    /// @inheritdoc IAaveAdapterViews
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc IAaveAdapterViews
    function RISK_MODULE() external view override returns (address riskModule) {
        riskModule = _RISK_MODULE;
    }

    /// @inheritdoc IAaveAdapterViews
    function MARKET_REGISTRY() external view override returns (address marketRegistry) {
        marketRegistry = _MARKET_REGISTRY;
    }

    /// @inheritdoc IAaveAdapterViews
    function PARAMETER_STORE() external view override returns (address parameterStore) {
        parameterStore = _PARAMETER_STORE;
    }

    /// @inheritdoc IAaveAdapterViews
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc IAaveAdapterViews
    function LOCK() external view override returns (address lock) {
        lock = _LOCK;
    }

    /// @inheritdoc IAaveAdapterViews
    function VAULT_TOKEN_FACTORY() external view override returns (address vaultTokenFactory) {
        vaultTokenFactory = _VAULT_TOKEN_FACTORY;
    }

    /// @inheritdoc IAaveAdapterViews
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _TIMELOCK;
    }

    /// @dev Either admin role can be held only by `TIMELOCK`.
    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        if ((role == DEFAULT_ADMIN_ROLE || role == AvanaRoles.APPLICATION_ADMIN) && account != _TIMELOCK) {
            revert AdminRoleOnlyTimelock(role, account);
        }
        granted = super._grantRole(role, account);
    }

    /// @dev Upgrades need `APPLICATION_ADMIN`, held by the timelock.
    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}

    /// @dev Runs the current call's body in `logic`, in this contract's storage; reverts bubble up unchanged.
    function _forward(
        address logic
    ) private returns (bytes memory ret) {
        ret = Address.functionDelegateCall(logic, msg.data);
    }

    function _requireLogic(
        address logic,
        bytes32 kind
    ) private view {
        (bytes32 k, bytes32 h) = IAaveAdapterLogic(logic).logicConfig();
        if (k != kind || h != _IMMUTABLES_HASH) revert InvalidLogic(logic);
    }
}
