// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {IProxyManager} from "../../proxy/proxy-manager/IProxyManager.sol";
import {PositionRef} from "../../types/PositionRef.sol";
import {IMarketRegistryViews} from "../market-registry/IMarketRegistryViews.sol";
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
/// @notice The chain's single entry point for every borrower action on every CDP Spoke (spec 2.6): roles, views and
/// upgrade gate here, entry-point bodies in four immutable logic contracts.
/// @dev UUPS implementation behind one fixed ERC-1967 proxy; `_authorizeUpgrade` requires `APPLICATION_ADMIN`, held
/// only by the timelock, and `_grantRole` gives `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` to `TIMELOCK` only. Every
/// entry point delegatecalls its logic contract with the unchanged calldata: the logic addresses are implementation
/// immutables whose `logicConfig()` the constructor checks, so a new logic contract is part of a new implementation and
/// waits the normal delay of `upgradeToAndCall`, and the Adapter delegatecalls no other code (REQ-LOCK-030). All state
/// is in the ERC-7201 namespace `avana.storage.AaveAdapter`; the router holds no token and makes only view calls of its
/// own.
/// @custom:spec REQ-ADAPTER-001, REQ-ADAPTER-002, REQ-ADAPTER-003, REQ-ADAPTER-004, REQ-ADAPTER-005, REQ-ADAPTER-006, REQ-ADAPTER-007, REQ-ADAPTER-008, REQ-ADAPTER-040, REQ-ADAPTER-041, REQ-ADAPTER-050, REQ-ADAPTER-051, REQ-ADAPTER-074, REQ-ADAPTER-084, REQ-ADAPTER-093, REQ-ADAPTER-095, REQ-ADAPTER-098, REQ-ADAPTER-100, REQ-PROXY-025, REQ-PROXY-049, Q-223, Q-226, Q-259
contract AaveAdapter is IAaveAdapter, UUPSUpgradeable, AccessControlUpgradeable, AaveAdapterStorage {
    /// @dev `pledge`, `borrow`, `repay`.
    address internal immutable _USER_LOGIC;
    /// @dev `withdraw`, `repayAllAndWithdraw`, `collectFees`, `releaseZeroCredit`, `refreshDebtMark`.
    address internal immutable _EXIT_LOGIC;
    /// @dev `removeLiquidity`, `recredit`, `repayWithCollateral`.
    address internal immutable _COLLATERAL_LOGIC;
    /// @dev `burnSeized`, `deleverageRepay`, `deleverageRelease`.
    address internal immutable _SETTLEMENT_LOGIC;

    /// @notice Fixes the implementation immutables, checks each logic contract and disables initializers on the
    /// implementation itself.
    /// @param im The chain's dependencies.
    /// @param logics The four logic contracts, each built with `im`.
    /// @custom:spec REQ-ADAPTER-004, REQ-ADAPTER-074
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
    /// @custom:spec REQ-ADAPTER-074, REQ-ADAPTER-084
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

    // ─── Borrower entry points (AaveAdapterUserLogic, AaveAdapterExitLogic) ───

    /// @inheritdoc IAaveAdapterUser
    /// @custom:spec REQ-ADAPTER-065
    function pledge(
        uint256,
        PositionRef calldata,
        uint256
    ) external override returns (address proxy, uint256 recordId, uint128 credited) {
        (proxy, recordId, credited) = abi.decode(_forward(_USER_LOGIC), (address, uint256, uint128));
    }

    /// @inheritdoc IAaveAdapterUser
    /// @custom:spec REQ-PROXY-015
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
    /// @custom:spec REQ-PROXY-027
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
    /// @custom:spec REQ-PROXY-033
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
    /// @custom:spec REQ-ADAPTER-071
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
    /// @custom:spec REQ-ADAPTER-097
    function releaseZeroCredit(
        uint256,
        PositionRef calldata,
        uint256
    ) external override {
        _forward(_EXIT_LOGIC);
    }

    /// @inheritdoc IAaveAdapterUser
    /// @custom:spec REQ-ADAPTER-096
    function collectFees(
        uint256,
        PositionRef calldata,
        uint256
    ) external override returns (uint256[] memory fees) {
        fees = abi.decode(_forward(_EXIT_LOGIC), (uint256[]));
    }

    /// @inheritdoc IAaveAdapterUser
    /// @custom:spec REQ-ADAPTER-104
    function refreshDebtMark(
        address
    ) external override {
        _forward(_EXIT_LOGIC);
    }

    // ─── Records changed in place (AaveAdapterCollateralLogic) ───

    /// @inheritdoc IAaveAdapterCollateral
    /// @custom:spec REQ-ADAPTER-078
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
    /// @custom:spec REQ-ADAPTER-079
    function recredit(
        uint256,
        PositionRef calldata,
        bytes calldata,
        uint256
    ) external override returns (uint128 added) {
        added = abi.decode(_forward(_COLLATERAL_LOGIC), (uint128));
    }

    /// @inheritdoc IAaveAdapterCollateral
    /// @custom:spec REQ-ADAPTER-080
    function repayWithCollateral(
        RepayWithCollateralParams calldata
    ) external override returns (uint256 debtRepaid, uint256 debtAssetToWallet) {
        (debtRepaid, debtAssetToWallet) = abi.decode(_forward(_COLLATERAL_LOGIC), (uint256, uint256));
    }

    // ─── LPVaultSwap's steps (AaveAdapterSettlementLogic) ───

    /// @inheritdoc IAaveAdapterSettlement
    /// @custom:spec REQ-ADAPTER-070
    function burnSeized(
        uint256,
        address,
        uint256
    ) external override {
        _forward(_SETTLEMENT_LOGIC);
    }

    /// @inheritdoc IAaveAdapterSettlement
    /// @custom:spec REQ-ADAPTER-081
    function deleverageRepay(
        address,
        uint256,
        uint256
    ) external override returns (uint256 repaid) {
        repaid = abi.decode(_forward(_SETTLEMENT_LOGIC), (uint256));
    }

    /// @inheritdoc IAaveAdapterSettlement
    /// @custom:spec REQ-ADAPTER-081
    function deleverageRelease(
        address,
        PositionRef calldata,
        uint128,
        uint256[] calldata
    ) external override returns (uint256[] memory amounts, bool closed) {
        (amounts, closed) = abi.decode(_forward(_SETTLEMENT_LOGIC), (uint256[], bool));
    }

    // ─── Views ───

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-ADAPTER-066, REQ-PROXY-049
    function proxyOf(
        address wallet,
        uint256 marketId
    ) external view override returns (address proxy) {
        proxy = _s().proxyOf[wallet][marketId];
    }

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-ADAPTER-066, REQ-PROXY-049, REQ-PROXY-055
    function walletOf(
        address proxy
    ) external view override returns (address wallet) {
        wallet = _s().walletOf[proxy];
    }

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-ADAPTER-066, REQ-PROXY-049
    function accountOf(
        address proxy
    ) external view override returns (address spoke, uint256 marketId, address vaultToken, uint256 reserveId) {
        AdapterAccount storage a = _s().accountOf[proxy];
        (spoke, marketId, vaultToken, reserveId) = (a.spoke, a.marketId, a.vaultToken, a.reserveId);
    }

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-PROXY-049, REQ-PROXY-052
    function predictProxy(
        address wallet,
        uint256 marketId
    ) external view override returns (address proxy) {
        proxy = _s().proxyOf[wallet][marketId];
        if (proxy != address(0)) return proxy;
        address spoke = IMarketRegistryViews(_MARKET_REGISTRY).getMarket(marketId).spoke;
        proxy = IProxyManager(_PROXY_MANAGER).predictProxy(wallet, spoke, marketId);
    }

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-PROXY-015, REQ-PROXY-049, INV-019
    function borrowNonce(
        address proxy
    ) external view override returns (uint256 nonce) {
        nonce = _s().borrowNonce[proxy];
    }

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-ADAPTER-003
    function APPLICATION_ADMIN() external pure override returns (bytes32 role) {
        role = AvanaRoles.APPLICATION_ADMIN;
    }

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-ADAPTER-074
    function PROXY_MANAGER() external view override returns (address proxyManager) {
        proxyManager = _PROXY_MANAGER;
    }

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-ADAPTER-074
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-ADAPTER-074
    function RISK_MODULE() external view override returns (address riskModule) {
        riskModule = _RISK_MODULE;
    }

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-ADAPTER-074
    function MARKET_REGISTRY() external view override returns (address marketRegistry) {
        marketRegistry = _MARKET_REGISTRY;
    }

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-ADAPTER-074
    function PARAMETER_STORE() external view override returns (address parameterStore) {
        parameterStore = _PARAMETER_STORE;
    }

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-ADAPTER-074
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-ADAPTER-074
    function LOCK() external view override returns (address lock) {
        lock = _LOCK;
    }

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-ADAPTER-074
    function VAULT_TOKEN_FACTORY() external view override returns (address vaultTokenFactory) {
        vaultTokenFactory = _VAULT_TOKEN_FACTORY;
    }

    /// @inheritdoc IAaveAdapterViews
    /// @custom:spec REQ-ADAPTER-084
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _TIMELOCK;
    }

    // ─── Roles, upgrade and dispatch ───

    /// @dev Either admin role can be held only by `TIMELOCK`, through `initialize` or any later grant (REQ-ADAPTER-084).
    /// @custom:spec REQ-ADAPTER-084, REQ-ADAPTER-093
    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        if ((role == DEFAULT_ADMIN_ROLE || role == AvanaRoles.APPLICATION_ADMIN) && account != _TIMELOCK) {
            revert AdminRoleOnlyTimelock(role, account);
        }
        granted = super._grantRole(role, account);
    }

    /// @dev Upgrades need `APPLICATION_ADMIN`, the timelock (REQ-ADAPTER-003).
    /// @custom:spec REQ-ADAPTER-003
    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}

    /// @dev Runs the current call's body in `logic`, in this contract's storage; reverts bubble up unchanged.
    function _forward(
        address logic
    ) private returns (bytes memory ret) {
        ret = Address.functionDelegateCall(logic, msg.data);
    }

    /// @dev Reverts unless `logic` reports `kind` and the same implementation immutables.
    function _requireLogic(
        address logic,
        bytes32 kind
    ) private view {
        (bytes32 k, bytes32 h) = IAaveAdapterLogic(logic).logicConfig();
        if (k != kind || h != _IMMUTABLES_HASH) revert InvalidLogic(logic);
    }
}
