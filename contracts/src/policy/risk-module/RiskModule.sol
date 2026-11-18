// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {AccountGateStatus} from "../../types/AccountGateStatus.sol";
import {DriftReason} from "../../types/DriftReason.sol";
import {Market} from "../../types/Market.sol";
import {PauseReason} from "../../types/PauseReason.sol";
import {PauseState} from "../../types/PauseState.sol";
import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {PledgePreview} from "../../types/PledgePreview.sol";
import {BreakerReasons} from "../market-registry/types/Breaker.sol";
import {MarketStatus} from "../market-registry/types/MarketRegistryTypes.sol";
import {IRiskModule} from "./IRiskModule.sol";
import {IRiskModuleAdmin} from "./IRiskModuleAdmin.sol";
import {IRiskModuleBorrowLogic} from "./IRiskModuleBorrowLogic.sol";
import {IRiskModuleBreakerLogic} from "./IRiskModuleBreakerLogic.sol";
import {IRiskModuleChecks} from "./IRiskModuleChecks.sol";
import {IRiskModuleDriftLogic} from "./IRiskModuleDriftLogic.sol";
import {IRiskModulePledgeLogic} from "./IRiskModulePledgeLogic.sol";
import {IRiskModuleSpeedLogic} from "./IRiskModuleSpeedLogic.sol";
import {IRiskModuleStatusLogic} from "./IRiskModuleStatusLogic.sol";
import {IRiskModuleViews} from "./IRiskModuleViews.sol";
import {RiskModuleBase} from "./RiskModuleBase.sol";
import {RiskModuleConstants} from "./RiskModuleConstants.sol";
import {RiskModuleSpeed} from "./RiskModuleSpeed.sol";
import {PledgeCharge} from "./types/PledgeCharge.sol";
import {RiskModuleImmutables} from "./types/RiskModuleImmutables.sol";
import {RiskModuleLogics} from "./types/RiskModuleLogics.sol";
import {SpeedScope} from "./types/SpeedScope.sol";
import {SpeedView} from "./types/SpeedView.sol";
import {SpeedWindow} from "./types/SpeedWindow.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title RiskModule
/// @notice Avana's risk checks on one chain: pledge, borrow-side, speed-limit, drift and breaker checks.
/// @dev UUPS proxy; only the timelock can upgrade it. Check bodies run in six stateless logic contracts.
contract RiskModule is UUPSUpgradeable, AccessControlUpgradeable, RiskModuleSpeed, IRiskModule {
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

    /// @inheritdoc IRiskModuleAdmin
    function initialize(
        address timelock
    ) external override initializer {
        if (timelock != _TIMELOCK) revert AdminRoleOnlyTimelock(DEFAULT_ADMIN_ROLE, timelock);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        _grantRole(AvanaRoles.APPLICATION_ADMIN, timelock);
    }

    /// @inheritdoc IRiskModuleChecks
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

    /// @inheritdoc IRiskModuleChecks
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

    /// @inheritdoc IRiskModuleChecks
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

    /// @inheritdoc IRiskModuleChecks
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

    /// @inheritdoc IRiskModuleChecks
    function preWithdrawCheck(
        address proxy
    ) external override {
        IRiskModuleBorrowLogic(_BORROW_LOGIC).preCheck(proxy, type(uint256).max, false);
    }

    /// @inheritdoc IRiskModuleChecks
    function postHealthCheck(
        address proxy,
        uint256 minHealthFactor
    ) external view override returns (uint256 healthFactor) {
        healthFactor = IRiskModuleBorrowLogic(_BORROW_LOGIC).postHealthCheck(proxy, minHealthFactor);
    }

    /// @inheritdoc IRiskModuleChecks
    function checkAaveConfig(
        address spoke,
        uint256[] calldata marketIds
    ) external view override {
        (uint256 marketId, DriftReason reason) =
            IRiskModuleDriftLogic(_DRIFT_LOGIC).driftOf(spoke, marketIds, address(0));
        if (reason != DriftReason.None) revert ConfigDrift(marketId, reason);
    }

    /// @inheritdoc IRiskModuleChecks
    function pokeConfig(
        address spoke
    ) external override returns (DriftReason reason) {
        if (!_registry().getSpoke(spoke).approved) revert UnknownSpoke(spoke);
        // The breach is recorded on every market of the Spoke, so the market the reason was found on is not used.
        // forge-lint: disable-next-line(unused-return)
        (, reason) = IRiskModuleDriftLogic(_DRIFT_LOGIC).spokeDrift(spoke);
        if (reason == DriftReason.None) return reason;
        emit ConfigDriftDetected(spoke, reason);
        uint256[] memory ids = _registry().marketsOfSpoke(spoke);
        for (uint256 i = 0; i < ids.length; ++i) {
            MarketStatus status = _market(ids[i]).status;
            if (status != MarketStatus.Active && status != MarketStatus.Offboarding) continue;
            // Bounded by the Spoke's markets.
            // forge-lint: disable-next-line(calls-loop)
            _registry().recordBreach(bytes32(ids[i]), BreakerReasons.CONFIG_DRIFT);
        }
    }

    /// @inheritdoc IRiskModuleChecks
    function pokeBreakers(
        uint256 marketId
    ) external override returns (uint32 reasons) {
        Market memory m = _market(marketId);
        IRiskModuleBreakerLogic b = IRiskModuleBreakerLogic(_BREAKER_LOGIC);
        b.pokeOracles(marketId);
        uint32 live = b.marketConditions(marketId, false, 0);
        if (live != 0) _registry().recordBreach(bytes32(marketId), live);
        reasons = live;
        uint256[] memory ids = _registry().getDebtReserveIds(m.spoke);
        for (uint256 i = 0; i < ids.length; ++i) {
            // Bounded by the Spoke's listed debt reserves.
            // forge-lint: disable-next-line(calls-loop)
            uint32 d = b.debtConditions(m.spoke, ids[i]);
            if (d == 0) continue;
            // forge-lint: disable-next-line(calls-loop)
            _registry().recordBreach(_debtKey(m.spoke, ids[i]), d);
            reasons |= d;
        }
        // The only external calls are to the MarketRegistry, an Avana contract that makes no calls back.
        // forge-lint: disable-next-line(reentrancy-events)
        emit BreakersPoked(marketId, reasons);
    }

    /// @inheritdoc IRiskModuleChecks
    function isHubSharesEqualAssets(
        uint256 marketId
    ) external view override returns (bool equal) {
        equal = IRiskModuleDriftLogic(_DRIFT_LOGIC).isHubSharesEqualAssets(marketId);
    }

    /// @inheritdoc IRiskModuleChecks
    function checkRemainingRecord(
        uint256 marketId,
        uint128 remainingUnits
    ) external view override {
        IRiskModulePledgeLogic(_PLEDGE_LOGIC).checkRemainingRecord(marketId, remainingUnits);
    }

    /// @inheritdoc IRiskModuleViews
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

    /// @inheritdoc IRiskModuleViews
    function getAccountGateStatus(
        address proxy
    ) external view override returns (AccountGateStatus memory status) {
        IRiskModuleStatusLogic logic = IRiskModuleStatusLogic(_STATUS_LOGIC);
        try logic.getAccountGateStatus(proxy) returns (AccountGateStatus memory s) {
            status = s;
        } catch {
            return _unavailable();
        }
        try logic.pauseOf(proxy) returns (PauseState state, PauseReason reason) {
            (status.pauseState, status.pauseReason) = (state, reason);
        } catch {
            return _unavailable();
        }
    }

    /// @dev The status when it cannot be computed: nothing allowed, every reserve field `type(uint256).max`.
    function _unavailable() internal pure returns (AccountGateStatus memory status) {
        status.statusUnavailable = true;
        status.unknownCollateralReserveId = type(uint256).max;
        status.unapprovedDebtReserveId = type(uint256).max;
        status.pausedDebtReserveId = type(uint256).max;
        status.staleDebtReserveId = type(uint256).max;
        status.haltedDebtReserveId = type(uint256).max;
        status.breakerDebtReserveId = type(uint256).max;
    }

    /// @inheritdoc IRiskModuleViews
    function usdToRestore(
        address proxy
    ) external view override returns (uint256 usd) {
        usd = IRiskModulePledgeLogic(_PLEDGE_LOGIC).usdToRestore(proxy);
    }

    /// @inheritdoc IRiskModuleViews
    function expectedCollateralFactorBps(
        uint256 marketId
    ) external view override returns (uint256 cfBps) {
        cfBps = IRiskModuleDriftLogic(_DRIFT_LOGIC).expectedCollateralFactorBps(marketId);
    }

    /// @inheritdoc IRiskModuleViews
    function getBreakerStatus(
        uint256 marketId
    ) external view override returns (uint32 reasons, uint64 reopensAt) {
        try IRiskModuleBreakerLogic(_BREAKER_LOGIC).marketBreaker(marketId, false, 0) returns (uint32 r, uint64 t) {
            (reasons, reopensAt) = (r, t);
        } catch {
            reasons = BreakerReasons.TEMPORARY | BreakerReasons.SECURITY;
        }
    }

    /// @inheritdoc IRiskModuleViews
    function getDebtBreakerStatus(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (uint32 reasons, uint64 reopensAt) {
        try IRiskModuleBreakerLogic(_BREAKER_LOGIC).debtBreaker(spoke, debtReserveId) returns (uint32 r, uint64 t) {
            (reasons, reopensAt) = (r, t);
        } catch {
            reasons = BreakerReasons.TEMPORARY | BreakerReasons.SECURITY;
        }
    }

    /// @inheritdoc IRiskModuleViews
    /// @dev Never reverts: a failed evaluation reports every security reason, so a reset is refused.
    function liveBreakerReasons(
        uint256 marketId
    ) external view override returns (uint32 reasons) {
        try IRiskModuleBreakerLogic(_BREAKER_LOGIC).marketConditions(marketId, false, 0) returns (uint32 r) {
            reasons = r & BreakerReasons.SECURITY;
        } catch {
            reasons = BreakerReasons.SECURITY;
        }
    }

    /// @inheritdoc IRiskModuleViews
    /// @dev Never reverts: a failed evaluation reports every security reason, so a reset is refused.
    function liveDebtBreakerReasons(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (uint32 reasons) {
        try IRiskModuleBreakerLogic(_BREAKER_LOGIC).debtConditions(spoke, debtReserveId) returns (uint32 r) {
            reasons = r & BreakerReasons.SECURITY;
        } catch {
            reasons = BreakerReasons.SECURITY;
        }
    }

    /// @inheritdoc IRiskModuleViews
    function checkBorrowGate(
        address proxy,
        uint256 debtReserveId
    ) external view override {
        IRiskModuleBorrowLogic(_BORROW_LOGIC).gate(proxy, debtReserveId, true);
    }

    /// @inheritdoc IRiskModuleViews
    function debtValueUsd(
        address proxy
    ) external view override returns (uint256 usd) {
        usd = IRiskModuleBorrowLogic(_BORROW_LOGIC).debtValueUsd(proxy);
    }

    /// @inheritdoc IRiskModuleViews
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

    /// @inheritdoc IRiskModuleViews
    function getPledgeSpeed(
        uint256 marketId
    ) external view override returns (SpeedView memory pledge) {
        try IRiskModuleSpeedLogic(_SPEED_LOGIC).pledgeView(marketId) returns (SpeedView memory v) {
            pledge = v;
        } catch {
            pledge.unavailable = true;
        }
    }

    /// @inheritdoc IRiskModuleViews
    function getSpeedWindow(
        SpeedScope scope,
        bytes32 key
    ) external view override returns (SpeedWindow memory window) {
        window = _window(scope, key);
    }

    /// @inheritdoc IRiskModuleViews
    function rescueHealthFactor() external pure override returns (uint256 value) {
        value = RiskModuleConstants.RESCUE_HEALTH_FACTOR;
    }

    /// @inheritdoc IRiskModuleViews
    function RESCUE_MIN_PLEDGE_USD() external pure override returns (uint256 usd) {
        usd = RiskModuleConstants.RESCUE_MIN_PLEDGE_USD;
    }

    /// @inheritdoc IRiskModuleViews
    function MARKET_REGISTRY() external view override returns (address marketRegistry) {
        marketRegistry = _MARKET_REGISTRY;
    }

    /// @inheritdoc IRiskModuleViews
    function PARAMETER_STORE() external view override returns (address parameterStore) {
        parameterStore = _PARAMETER_STORE;
    }

    /// @inheritdoc IRiskModuleViews
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc IRiskModuleViews
    function ADAPTER() external view override returns (address adapter) {
        adapter = _ADAPTER;
    }

    /// @inheritdoc IRiskModuleViews
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc IRiskModuleViews
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
