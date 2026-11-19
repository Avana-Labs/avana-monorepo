// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BreakerReasons} from "../../policy/market-registry/types/Breaker.sol";
import {AccountGateStatus, DriftReason} from "../../types/MarketTypes.sol";
import {PledgeCounters, PledgePreview} from "../../types/PositionTypes.sol";
import {ILegacyRiskModule} from "./ILegacyRiskModule.sol";
import {IRiskModuleBorrowLogic} from "./IRiskModuleBorrowLogic.sol";
import {IRiskModuleBreakerLogic} from "./IRiskModuleBreakerLogic.sol";
import {IRiskModuleDriftLogic} from "./IRiskModuleDriftLogic.sol";
import {IRiskModuleDynamicCapLogic} from "./IRiskModuleDynamicCapLogic.sol";
import {IRiskModulePledgeLogic} from "./IRiskModulePledgeLogic.sol";
import {IRiskModuleStatusLogic} from "./IRiskModuleStatusLogic.sol";
import {RiskModuleBase} from "./RiskModuleBase.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";
import {DynamicCap, PledgeCharge, RiskModuleImmutables, RiskModuleLogics} from "./types/RiskModuleTypes.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title LegacyRiskModule
/// @notice Avana's risk checks on one chain: pledge, borrow-side, dynamic borrow cap, drift and live breaker checks.
/// @dev UUPS proxy; only the AccessManager's governance role can upgrade it. Check bodies run in six stateless logic contracts.
contract LegacyRiskModule is UUPSUpgradeable, AccessManagedUpgradeable, RiskModuleBase, ILegacyRiskModule {
    /// @custom:storage-location erc7201:avana.storage.LegacyRiskModule.dynamicCap
    struct DynamicCapLayout {
        mapping(uint256 marketId => DynamicCap) marketBorrowCap;
    }

    /// @dev `keccak256(abi.encode(uint256(keccak256("avana.storage.LegacyRiskModule.dynamicCap")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _DYNAMIC_CAP_SLOT = 0x39128d80f0178a14e89ab235df8bb39067415fbde0926f652a6e7f9d2722c100;

    function _dynamicCap() internal pure returns (DynamicCapLayout storage $) {
        // ERC-7201 namespaced storage: the slot is a compile-time constant.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _DYNAMIC_CAP_SLOT
        }
    }

    address internal immutable _DRIFT_LOGIC;
    address internal immutable _BREAKER_LOGIC;
    address internal immutable _PLEDGE_LOGIC;
    address internal immutable _BORROW_LOGIC;
    address internal immutable _STATUS_LOGIC;
    address internal immutable _DYNAMIC_CAP_LOGIC;

    constructor(
        RiskModuleImmutables memory im,
        RiskModuleLogics memory logics
    ) RiskModuleBase(im) {
        _requireLogic(logics.drift, keccak256("RiskModuleDriftLogic"));
        _requireLogic(logics.breaker, keccak256("RiskModuleBreakerLogic"));
        _requireLogic(logics.pledge, keccak256("RiskModulePledgeLogic"));
        _requireLogic(logics.borrow, keccak256("RiskModuleBorrowLogic"));
        _requireLogic(logics.status, keccak256("RiskModuleStatusLogic"));
        _requireLogic(logics.dynamicCap, keccak256("RiskModuleDynamicCapLogic"));
        _DRIFT_LOGIC = logics.drift;
        _BREAKER_LOGIC = logics.breaker;
        _PLEDGE_LOGIC = logics.pledge;
        _BORROW_LOGIC = logics.borrow;
        _STATUS_LOGIC = logics.status;
        _DYNAMIC_CAP_LOGIC = logics.dynamicCap;
        _disableInitializers();
    }

    /// @inheritdoc ILegacyRiskModule
    function initialize(
        address authority
    ) external override initializer {
        __AccessManaged_init(authority);
        __UUPSUpgradeable_init();
    }

    /// @inheritdoc ILegacyRiskModule
    function checkPledge(
        address depositor,
        address proxy,
        uint256 marketId,
        uint32 integrationId,
        bytes32 positionKey,
        uint128 units,
        PledgeCounters calldata counters,
        bool requireRescue
    ) external view override returns (PledgeCharge memory charge) {
        charge = IRiskModulePledgeLogic(_PLEDGE_LOGIC)
            .checkPledge(depositor, proxy, marketId, integrationId, positionKey, units, counters, requireRescue);
    }

    /// @inheritdoc ILegacyRiskModule
    function preBorrowCheck(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external override {
        IRiskModuleBorrowLogic(_BORROW_LOGIC).preCheck(proxy, debtReserveId, true);
        (uint256 marketId, DynamicCap memory next) =
            IRiskModuleDynamicCapLogic(_DYNAMIC_CAP_LOGIC).borrowCheck(proxy, debtReserveId, amount);
        if (msg.sender == _ADAPTER) _dynamicCap().marketBorrowCap[marketId] = next;
    }

    /// @inheritdoc ILegacyRiskModule
    function preWithdrawCheck(
        address proxy
    ) external override {
        IRiskModuleBorrowLogic(_BORROW_LOGIC).preCheck(proxy, type(uint256).max, false);
    }

    /// @inheritdoc ILegacyRiskModule
    function postHealthCheck(
        address proxy,
        uint256 minHealthFactor
    ) external view override returns (uint256 healthFactor) {
        healthFactor = IRiskModuleBorrowLogic(_BORROW_LOGIC).postHealthCheck(proxy, minHealthFactor);
    }

    /// @inheritdoc ILegacyRiskModule
    function checkAaveConfig(
        address spoke,
        uint256[] calldata marketIds
    ) external view override {
        (uint256 marketId, DriftReason reason) =
            IRiskModuleDriftLogic(_DRIFT_LOGIC).driftOf(spoke, marketIds, address(0));
        if (reason != DriftReason.None) revert ConfigDrift(marketId, reason);
    }

    /// @inheritdoc ILegacyRiskModule
    function pokeConfig(
        address spoke
    ) external override returns (DriftReason reason) {
        if (!_registry().getSpoke(spoke).approved) revert UnknownSpoke(spoke);
        // The drift holds every market of the Spoke, so the market the reason was found on is not used.
        // forge-lint: disable-next-line(unused-return)
        (, reason) = IRiskModuleDriftLogic(_DRIFT_LOGIC).spokeDrift(spoke);
        if (reason != DriftReason.None) emit ConfigDriftDetected(spoke, reason);
    }

    /// @inheritdoc ILegacyRiskModule
    function isHubSharesEqualAssets(
        uint256 marketId
    ) external view override returns (bool equal) {
        equal = IRiskModuleDriftLogic(_DRIFT_LOGIC).isHubSharesEqualAssets(marketId);
    }

    /// @inheritdoc ILegacyRiskModule
    function checkRemainingRecord(
        uint256 marketId,
        uint128 remainingUnits
    ) external view override {
        IRiskModulePledgeLogic(_PLEDGE_LOGIC).checkRemainingRecord(marketId, remainingUnits);
    }

    /// @inheritdoc ILegacyRiskModule
    /// @dev Never reverts: a failure of the preview body is reported as `eligible = false` with its selector.
    function previewPledge(
        address depositor,
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (PledgePreview memory preview) {
        try IRiskModulePledgeLogic(_PLEDGE_LOGIC).previewPledge(depositor, marketId, positionKey) returns (
            PledgePreview memory p
        ) {
            preview = p;
        } catch (bytes memory err) {
            // The revert selector is the first four bytes of the revert data.
            // forge-lint: disable-next-line(unsafe-typecast)
            preview.reason = bytes4(err);
        }
    }

    /// @inheritdoc ILegacyRiskModule
    function getAccountGateStatus(
        address proxy
    ) external view override returns (AccountGateStatus memory status) {
        IRiskModuleStatusLogic logic = IRiskModuleStatusLogic(_STATUS_LOGIC);
        try logic.getAccountGateStatus(proxy) returns (AccountGateStatus memory s) {
            status = s;
        } catch {
            return _unavailable();
        }
    }

    /// @dev The status when it cannot be computed: nothing allowed, every reserve field `type(uint256).max`.
    function _unavailable() internal pure returns (AccountGateStatus memory status) {
        status.statusUnavailable = true;
        status.unknownCollateralReserveId = type(uint256).max;
        status.unapprovedDebtReserveId = type(uint256).max;
        status.staleDebtReserveId = type(uint256).max;
        status.haltedDebtReserveId = type(uint256).max;
        status.breakerDebtReserveId = type(uint256).max;
    }

    /// @inheritdoc ILegacyRiskModule
    function usdToRestore(
        address proxy
    ) external view override returns (uint256 usd) {
        usd = IRiskModulePledgeLogic(_PLEDGE_LOGIC).usdToRestore(proxy);
    }

    /// @inheritdoc ILegacyRiskModule
    function expectedCollateralFactorBps(
        uint256 marketId
    ) external view override returns (uint256 cfBps) {
        cfBps = IRiskModuleDriftLogic(_DRIFT_LOGIC).expectedCollateralFactorBps(marketId);
    }

    /// @inheritdoc ILegacyRiskModule
    /// @dev Never reverts: a failed evaluation reports every market reason.
    function getBreakerStatus(
        uint256 marketId
    ) external view override returns (uint32 reasons) {
        try IRiskModuleBreakerLogic(_BREAKER_LOGIC).marketConditions(marketId) returns (uint32 r) {
            reasons = r;
        } catch {
            reasons = BreakerReasons.MARKET;
        }
    }

    /// @inheritdoc ILegacyRiskModule
    /// @dev Never reverts: a failed evaluation reports every debt reason.
    function getDebtBreakerStatus(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (uint32 reasons) {
        try IRiskModuleBreakerLogic(_BREAKER_LOGIC).debtConditions(spoke, debtReserveId) returns (uint32 r) {
            reasons = r;
        } catch {
            reasons = BreakerReasons.DEBT;
        }
    }

    /// @inheritdoc ILegacyRiskModule
    function checkBorrowGate(
        address proxy,
        uint256 debtReserveId
    ) external view override {
        IRiskModuleBorrowLogic(_BORROW_LOGIC).gate(proxy, debtReserveId, true);
    }

    /// @inheritdoc ILegacyRiskModule
    function debtValueUsd(
        address proxy
    ) external view override returns (uint256 usd) {
        usd = IRiskModuleBorrowLogic(_BORROW_LOGIC).debtValueUsd(proxy);
    }

    /// @inheritdoc ILegacyRiskModule
    function getDynamicBorrowCap(
        uint256 marketId
    ) external view override returns (uint256 cap, uint256 debt, uint64 intervalStart) {
        (cap, debt, intervalStart) = IRiskModuleDynamicCapLogic(_DYNAMIC_CAP_LOGIC).capView(marketId);
    }

    /// @inheritdoc ILegacyRiskModule
    function getDynamicCap(
        uint256 marketId
    ) external view override returns (DynamicCap memory interval) {
        interval = _dynamicCap().marketBorrowCap[marketId];
    }

    /// @inheritdoc ILegacyRiskModule
    function rescueHealthFactor() external pure override returns (uint256 value) {
        value = RiskModuleMath.RESCUE_HEALTH_FACTOR;
    }

    /// @inheritdoc ILegacyRiskModule
    function RESCUE_MIN_PLEDGE_USD() external pure override returns (uint256 usd) {
        usd = RiskModuleMath.RESCUE_MIN_PLEDGE_USD;
    }

    /// @inheritdoc ILegacyRiskModule
    function MARKET_REGISTRY() external view override returns (address marketRegistry) {
        marketRegistry = _MARKET_REGISTRY;
    }

    /// @inheritdoc ILegacyRiskModule
    function PARAMETER_STORE() external view override returns (address parameterStore) {
        parameterStore = _PARAMETER_STORE;
    }

    /// @inheritdoc ILegacyRiskModule
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc ILegacyRiskModule
    function ADAPTER() external view override returns (address adapter) {
        adapter = _ADAPTER;
    }

    /// @inheritdoc ILegacyRiskModule
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @dev Upgrades need the AccessManager's governance role, after its execution delay.
    function _authorizeUpgrade(
        address
    ) internal override restricted {}
}
