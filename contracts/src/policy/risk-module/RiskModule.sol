// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {AccountGateStatus, DriftReason} from "../../types/MarketTypes.sol";
import {PledgeCounters, PledgePreview} from "../../types/PositionTypes.sol";
import {BreakerReasons} from "../market-registry/types/Breaker.sol";
import {IRiskModule} from "./IRiskModule.sol";
import {IRiskModuleBorrowLogic} from "./IRiskModuleBorrowLogic.sol";
import {IRiskModuleBreakerLogic} from "./IRiskModuleBreakerLogic.sol";
import {IRiskModuleDriftLogic} from "./IRiskModuleDriftLogic.sol";
import {IRiskModulePledgeLogic} from "./IRiskModulePledgeLogic.sol";
import {IRiskModuleSpeedLogic} from "./IRiskModuleSpeedLogic.sol";
import {IRiskModuleStatusLogic} from "./IRiskModuleStatusLogic.sol";
import {RiskModuleBase} from "./RiskModuleBase.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";
import {
    PledgeCharge,
    RiskModuleImmutables,
    RiskModuleLogics,
    SpeedScope,
    SpeedView,
    SpeedWindow
} from "./types/RiskModuleTypes.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title RiskModule
/// @notice Avana's risk checks on one chain: pledge, borrow-side, speed-limit, drift and live breaker checks.
/// @dev UUPS proxy; only the timelock can upgrade it. Check bodies run in six stateless logic contracts.
contract RiskModule is UUPSUpgradeable, AccessControlUpgradeable, RiskModuleBase, IRiskModule {
    /// @custom:storage-location erc7201:avana.storage.RiskModule.speed
    struct SpeedLayout {
        mapping(uint256 marketId => SpeedWindow) marketBorrow;
        mapping(bytes32 hubAssetKey => SpeedWindow) debtBorrow;
        mapping(uint256 marketId => SpeedWindow) marketPledge;
    }

    bytes32 private constant _SPEED_SLOT = 0x1858dc028745fe2a4f37a8a31dd3ca321a1f7863f165bffa26e588c97f1ff200;

    function _speed() internal pure returns (SpeedLayout storage $) {
        // ERC-7201 namespaced storage: the slot is a compile-time constant.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _SPEED_SLOT
        }
    }

    function _window(
        SpeedScope scope,
        bytes32 key
    ) internal view returns (SpeedWindow storage w) {
        SpeedLayout storage $ = _speed();
        if (scope == SpeedScope.DebtBorrow) return $.debtBorrow[key];
        if (scope == SpeedScope.MarketBorrow) return $.marketBorrow[uint256(key)];
        return $.marketPledge[uint256(key)];
    }

    function _putWindow(
        SpeedScope scope,
        bytes32 key,
        SpeedWindow memory w
    ) internal {
        SpeedWindow storage s = _window(scope, key);
        s.start = w.start;
        s.prev = w.prev;
        s.curr = w.curr;
        s.base = w.base;
        s.opened = w.opened;
    }

    address internal immutable _DRIFT_LOGIC;
    address internal immutable _BREAKER_LOGIC;
    address internal immutable _PLEDGE_LOGIC;
    address internal immutable _BORROW_LOGIC;
    address internal immutable _STATUS_LOGIC;
    address internal immutable _SPEED_LOGIC;

    constructor(
        RiskModuleImmutables memory im,
        RiskModuleLogics memory logics
    ) RiskModuleBase(im) {
        _requireLogic(logics.drift, keccak256("RiskModuleDriftLogic"));
        _requireLogic(logics.breaker, keccak256("RiskModuleBreakerLogic"));
        _requireLogic(logics.pledge, keccak256("RiskModulePledgeLogic"));
        _requireLogic(logics.borrow, keccak256("RiskModuleBorrowLogic"));
        _requireLogic(logics.status, keccak256("RiskModuleStatusLogic"));
        _requireLogic(logics.speed, keccak256("RiskModuleSpeedLogic"));
        _DRIFT_LOGIC = logics.drift;
        _BREAKER_LOGIC = logics.breaker;
        _PLEDGE_LOGIC = logics.pledge;
        _BORROW_LOGIC = logics.borrow;
        _STATUS_LOGIC = logics.status;
        _SPEED_LOGIC = logics.speed;
        _disableInitializers();
    }

    /// @inheritdoc IRiskModule
    function initialize(
        address timelock
    ) external override initializer {
        if (timelock != _TIMELOCK) revert AdminRoleOnlyTimelock(DEFAULT_ADMIN_ROLE, timelock);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        _grantRole(AvanaRoles.APPLICATION_ADMIN, timelock);
    }

    /// @inheritdoc IRiskModule
    function checkPledge(
        address depositor,
        address proxy,
        uint256 marketId,
        uint32 integrationId,
        bytes32 positionKey,
        uint128 units,
        PledgeCounters calldata counters,
        bool requireRescue
    ) external override returns (PledgeCharge memory charge) {
        charge = IRiskModulePledgeLogic(_PLEDGE_LOGIC)
            .checkPledge(depositor, proxy, marketId, integrationId, positionKey, units, counters, requireRescue);
        if (!charge.rescue) {
            uint256 booked = uint256(counters.regularUsed) + counters.sliceUsed;
            SpeedWindow memory w = IRiskModuleSpeedLogic(_SPEED_LOGIC).pledgeCharge(marketId, booked, charge.usdCharge);
            if (msg.sender == _COLLATERALIZATION) _putWindow(SpeedScope.MarketPledge, bytes32(marketId), w);
        }
    }

    /// @inheritdoc IRiskModule
    function preBorrowCheck(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external override {
        IRiskModuleBorrowLogic(_BORROW_LOGIC).preCheck(proxy, debtReserveId, true);
        (uint256 marketId, bytes32 debtKey, SpeedWindow memory m, SpeedWindow memory d) =
            IRiskModuleSpeedLogic(_SPEED_LOGIC).borrowCharge(proxy, debtReserveId, amount);
        if (msg.sender == _ADAPTER) _putBorrowWindows(marketId, debtKey, m, d);
    }

    /// @inheritdoc IRiskModule
    function creditRepay(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external override {
        if (msg.sender != _ADAPTER) revert NotSpeedWriter(msg.sender);
        (uint256 marketId, bytes32 debtKey, SpeedWindow memory m, SpeedWindow memory d) =
            IRiskModuleSpeedLogic(_SPEED_LOGIC).repayCredit(proxy, debtReserveId, amount);
        _putBorrowWindows(marketId, debtKey, m, d);
    }

    /// @inheritdoc IRiskModule
    function creditWithdraw(
        uint256 marketId,
        uint256 usd
    ) external override {
        if (msg.sender != _COLLATERALIZATION) revert NotSpeedWriter(msg.sender);
        SpeedWindow memory w = IRiskModuleSpeedLogic(_SPEED_LOGIC).withdrawCredit(marketId, usd);
        _putWindow(SpeedScope.MarketPledge, bytes32(marketId), w);
    }

    function _putBorrowWindows(
        uint256 marketId,
        bytes32 debtKey,
        SpeedWindow memory market,
        SpeedWindow memory debt
    ) internal {
        _putWindow(SpeedScope.MarketBorrow, bytes32(marketId), market);
        _putWindow(SpeedScope.DebtBorrow, debtKey, debt);
    }

    /// @inheritdoc IRiskModule
    function preWithdrawCheck(
        address proxy
    ) external override {
        IRiskModuleBorrowLogic(_BORROW_LOGIC).preCheck(proxy, type(uint256).max, false);
    }

    /// @inheritdoc IRiskModule
    function postHealthCheck(
        address proxy,
        uint256 minHealthFactor
    ) external view override returns (uint256 healthFactor) {
        healthFactor = IRiskModuleBorrowLogic(_BORROW_LOGIC).postHealthCheck(proxy, minHealthFactor);
    }

    /// @inheritdoc IRiskModule
    function checkAaveConfig(
        address spoke,
        uint256[] calldata marketIds
    ) external view override {
        (uint256 marketId, DriftReason reason) =
            IRiskModuleDriftLogic(_DRIFT_LOGIC).driftOf(spoke, marketIds, address(0));
        if (reason != DriftReason.None) revert ConfigDrift(marketId, reason);
    }

    /// @inheritdoc IRiskModule
    function pokeConfig(
        address spoke
    ) external override returns (DriftReason reason) {
        if (!_registry().getSpoke(spoke).approved) revert UnknownSpoke(spoke);
        // The drift holds every market of the Spoke, so the market the reason was found on is not used.
        // forge-lint: disable-next-line(unused-return)
        (, reason) = IRiskModuleDriftLogic(_DRIFT_LOGIC).spokeDrift(spoke);
        if (reason != DriftReason.None) emit ConfigDriftDetected(spoke, reason);
    }

    /// @inheritdoc IRiskModule
    function isHubSharesEqualAssets(
        uint256 marketId
    ) external view override returns (bool equal) {
        equal = IRiskModuleDriftLogic(_DRIFT_LOGIC).isHubSharesEqualAssets(marketId);
    }

    /// @inheritdoc IRiskModule
    function checkRemainingRecord(
        uint256 marketId,
        uint128 remainingUnits
    ) external view override {
        IRiskModulePledgeLogic(_PLEDGE_LOGIC).checkRemainingRecord(marketId, remainingUnits);
    }

    /// @inheritdoc IRiskModule
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

    /// @inheritdoc IRiskModule
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

    /// @inheritdoc IRiskModule
    function usdToRestore(
        address proxy
    ) external view override returns (uint256 usd) {
        usd = IRiskModulePledgeLogic(_PLEDGE_LOGIC).usdToRestore(proxy);
    }

    /// @inheritdoc IRiskModule
    function expectedCollateralFactorBps(
        uint256 marketId
    ) external view override returns (uint256 cfBps) {
        cfBps = IRiskModuleDriftLogic(_DRIFT_LOGIC).expectedCollateralFactorBps(marketId);
    }

    /// @inheritdoc IRiskModule
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

    /// @inheritdoc IRiskModule
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

    /// @inheritdoc IRiskModule
    function checkBorrowGate(
        address proxy,
        uint256 debtReserveId
    ) external view override {
        IRiskModuleBorrowLogic(_BORROW_LOGIC).gate(proxy, debtReserveId, true);
    }

    /// @inheritdoc IRiskModule
    function debtValueUsd(
        address proxy
    ) external view override returns (uint256 usd) {
        usd = IRiskModuleBorrowLogic(_BORROW_LOGIC).debtValueUsd(proxy);
    }

    /// @inheritdoc IRiskModule
    function getBorrowSpeed(
        uint256 marketId,
        uint256 debtReserveId
    ) external view override returns (SpeedView memory market, SpeedView memory debt) {
        try IRiskModuleSpeedLogic(_SPEED_LOGIC).borrowViews(marketId, debtReserveId) returns (
            SpeedView memory m, SpeedView memory d
        ) {
            (market, debt) = (m, d);
        } catch {
            (market.unavailable, debt.unavailable) = (true, true);
        }
    }

    /// @inheritdoc IRiskModule
    function getPledgeSpeed(
        uint256 marketId
    ) external view override returns (SpeedView memory pledge) {
        try IRiskModuleSpeedLogic(_SPEED_LOGIC).pledgeView(marketId) returns (SpeedView memory v) {
            pledge = v;
        } catch {
            pledge.unavailable = true;
        }
    }

    /// @inheritdoc IRiskModule
    function getSpeedWindow(
        SpeedScope scope,
        bytes32 key
    ) external view override returns (SpeedWindow memory window) {
        window = _window(scope, key);
    }

    /// @inheritdoc IRiskModule
    function rescueHealthFactor() external pure override returns (uint256 value) {
        value = RiskModuleMath.RESCUE_HEALTH_FACTOR;
    }

    /// @inheritdoc IRiskModule
    function RESCUE_MIN_PLEDGE_USD() external pure override returns (uint256 usd) {
        usd = RiskModuleMath.RESCUE_MIN_PLEDGE_USD;
    }

    /// @inheritdoc IRiskModule
    function MARKET_REGISTRY() external view override returns (address marketRegistry) {
        marketRegistry = _MARKET_REGISTRY;
    }

    /// @inheritdoc IRiskModule
    function PARAMETER_STORE() external view override returns (address parameterStore) {
        parameterStore = _PARAMETER_STORE;
    }

    /// @inheritdoc IRiskModule
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc IRiskModule
    function ADAPTER() external view override returns (address adapter) {
        adapter = _ADAPTER;
    }

    /// @inheritdoc IRiskModule
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc IRiskModule
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _TIMELOCK;
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

    /// @dev Upgrades need `APPLICATION_ADMIN`, held only by the timelock.
    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}
}
