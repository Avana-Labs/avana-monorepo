// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistry} from "../../policy/market-registry/IMarketRegistry.sol";
import {IProxyManager} from "../../proxy/proxy-manager/IProxyManager.sol";
import {PositionRef} from "../../types/PositionTypes.sol";
import {AaveAdapterStorage} from "./AaveAdapterStorage.sol";
import {IAaveAdapterLogic} from "./IAaveAdapterLogic.sol";
import {ILegacyAaveAdapter} from "./ILegacyAaveAdapter.sol";
import {
    AaveAdapterImmutables,
    AaveAdapterLogics,
    AdapterAccount,
    RepayWithCollateralParams
} from "./types/AaveAdapterTypes.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title AaveAdapter
/// @notice The chain's single entry point for every borrower action; entry-point bodies live in four logic contracts.
/// @dev UUPS proxy; only the AccessManager's governance role can upgrade it.
contract LegacyAaveAdapter is ILegacyAaveAdapter, UUPSUpgradeable, AccessManagedUpgradeable, AaveAdapterStorage {
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

    /// @inheritdoc ILegacyAaveAdapter
    function initialize(
        address authority
    ) external override initializer {
        if (authority == address(0)) revert ZeroAddress();
        __AccessManaged_init(authority);
        __UUPSUpgradeable_init();
    }

    /// @inheritdoc ILegacyAaveAdapter
    function pledge(
        uint256,
        PositionRef calldata,
        uint256
    ) external override returns (address proxy, uint256 recordId, uint128 credited) {
        (proxy, recordId, credited) = abi.decode(_forward(_USER_LOGIC), (address, uint256, uint128));
    }

    /// @inheritdoc ILegacyAaveAdapter
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

    /// @inheritdoc ILegacyAaveAdapter
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

    /// @inheritdoc ILegacyAaveAdapter
    function withdraw(
        uint256,
        PositionRef calldata,
        uint256,
        uint256,
        uint256
    ) external override {
        _forward(_EXIT_LOGIC);
    }

    /// @inheritdoc ILegacyAaveAdapter
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

    /// @inheritdoc ILegacyAaveAdapter
    function releaseZeroCredit(
        uint256,
        PositionRef calldata,
        uint256
    ) external override {
        _forward(_EXIT_LOGIC);
    }

    /// @inheritdoc ILegacyAaveAdapter
    function collectFees(
        uint256,
        PositionRef calldata,
        uint256
    ) external override returns (uint256[] memory fees) {
        fees = abi.decode(_forward(_EXIT_LOGIC), (uint256[]));
    }

    /// @inheritdoc ILegacyAaveAdapter
    function refreshDebtMark(
        address
    ) external override {
        _forward(_EXIT_LOGIC);
    }

    /// @inheritdoc ILegacyAaveAdapter
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

    /// @inheritdoc ILegacyAaveAdapter
    function recredit(
        uint256,
        PositionRef calldata,
        bytes calldata,
        uint256
    ) external override returns (uint128 added) {
        added = abi.decode(_forward(_COLLATERAL_LOGIC), (uint128));
    }

    /// @inheritdoc ILegacyAaveAdapter
    function repayWithCollateral(
        RepayWithCollateralParams calldata
    ) external override returns (uint256 debtRepaid, uint256 debtAssetToWallet) {
        (debtRepaid, debtAssetToWallet) = abi.decode(_forward(_COLLATERAL_LOGIC), (uint256, uint256));
    }

    /// @inheritdoc ILegacyAaveAdapter
    function burnSeized(
        uint256,
        address,
        uint256
    ) external override {
        _forward(_SETTLEMENT_LOGIC);
    }

    /// @inheritdoc ILegacyAaveAdapter
    function deleverageRepay(
        address,
        uint256,
        uint256
    ) external override returns (uint256 repaid) {
        repaid = abi.decode(_forward(_SETTLEMENT_LOGIC), (uint256));
    }

    /// @inheritdoc ILegacyAaveAdapter
    function deleverageRelease(
        address,
        PositionRef calldata,
        uint128,
        uint256[] calldata
    ) external override returns (uint256[] memory amounts, bool closed) {
        (amounts, closed) = abi.decode(_forward(_SETTLEMENT_LOGIC), (uint256[], bool));
    }

    /// @inheritdoc ILegacyAaveAdapter
    function proxyOf(
        address wallet,
        uint256 marketId
    ) external view override returns (address proxy) {
        proxy = _s().proxyOf[wallet][marketId];
    }

    /// @inheritdoc ILegacyAaveAdapter
    function walletOf(
        address proxy
    ) external view override returns (address wallet) {
        wallet = _s().walletOf[proxy];
    }

    /// @inheritdoc ILegacyAaveAdapter
    function accountOf(
        address proxy
    ) external view override returns (address spoke, uint256 marketId, address vaultToken, uint256 reserveId) {
        AdapterAccount storage a = _s().accountOf[proxy];
        (spoke, marketId, vaultToken, reserveId) = (a.spoke, a.marketId, a.vaultToken, a.reserveId);
    }

    /// @inheritdoc ILegacyAaveAdapter
    function predictProxy(
        address wallet,
        uint256 marketId
    ) external view override returns (address proxy) {
        proxy = _s().proxyOf[wallet][marketId];
        if (proxy != address(0)) return proxy;
        address spoke = IMarketRegistry(_MARKET_REGISTRY).getMarket(marketId).spoke;
        proxy = IProxyManager(_PROXY_MANAGER).predictProxy(wallet, spoke, marketId);
    }

    /// @inheritdoc ILegacyAaveAdapter
    function borrowNonce(
        address proxy
    ) external view override returns (uint256 nonce) {
        nonce = _s().borrowNonce[proxy];
    }

    /// @inheritdoc ILegacyAaveAdapter
    function PROXY_MANAGER() external view override returns (address proxyManager) {
        proxyManager = _PROXY_MANAGER;
    }

    /// @inheritdoc ILegacyAaveAdapter
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc ILegacyAaveAdapter
    function RISK_MODULE() external view override returns (address riskModule) {
        riskModule = _RISK_MODULE;
    }

    /// @inheritdoc ILegacyAaveAdapter
    function MARKET_REGISTRY() external view override returns (address marketRegistry) {
        marketRegistry = _MARKET_REGISTRY;
    }

    /// @inheritdoc ILegacyAaveAdapter
    function PARAMETER_STORE() external view override returns (address parameterStore) {
        parameterStore = _PARAMETER_STORE;
    }

    /// @inheritdoc ILegacyAaveAdapter
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc ILegacyAaveAdapter
    function LOCK() external view override returns (address lock) {
        lock = _LOCK;
    }

    /// @inheritdoc ILegacyAaveAdapter
    function VAULT_TOKEN_FACTORY() external view override returns (address vaultTokenFactory) {
        vaultTokenFactory = _VAULT_TOKEN_FACTORY;
    }

    /// @dev Upgrades need the AccessManager's governance role, after its execution delay.
    function _authorizeUpgrade(
        address
    ) internal override restricted {}

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
