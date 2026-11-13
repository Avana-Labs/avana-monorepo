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
import {MarketStatus} from "../market-registry/types/MarketStatus.sol";
import {MarketSpeedLimits} from "../parameter-store/types/MarketSpeedLimits.sol";
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
import {BorrowSpeedInputs} from "./types/BorrowSpeedInputs.sol";
import {PledgeCharge} from "./types/PledgeCharge.sol";
import {RiskModuleImmutables} from "./types/RiskModuleImmutables.sol";
import {RiskModuleLogics} from "./types/RiskModuleLogics.sol";
import {SpeedView} from "./types/SpeedView.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title RiskModule
/// @notice Avana's risk checks on one chain, holding no funds: the pledge check, the borrow-side pre- and post-checks,
/// the borrow-speed and pledge-speed limits, the Aave configuration drift check, the breaker pokes and their
/// non-reverting status views.
/// @dev UUPS implementation behind one fixed ERC-1967 proxy; `_authorizeUpgrade` requires `APPLICATION_ADMIN`, held only
/// by the timelock. Its state is the speed windows in the ERC-7201 namespace `avana.storage.RiskModule.speed`, written
/// only by the AaveAdapter's `preBorrowCheck` and Collateralization's `checkPledge` (REQ-RISK-095), and the OpenZeppelin
/// `AccessControl` roles in their ERC-7201 namespace. The check bodies run in six immutable, stateless logic contracts
/// by plain calls, because the whole surface does not fit the
/// 24,576-byte code limit; the logic addresses are implementation immutables whose `logicConfig()` the constructor
/// checks, so a new logic contract is part of a new implementation and waits the normal delay. The RiskModule itself
/// writes nothing but its roles and the speed windows and makes one state-changing call, `MarketRegistry.recordBreach` from `pokeBreakers`
/// and `pokeConfig`; the logic contracts' only state-changing calls are LPOracle and DebtOracle `poke()`. No token, NFT
/// or debt asset moves through it, and no exit or liquidation path calls it (REQ-RISK-005).
/// @custom:spec REQ-RISK-001, REQ-RISK-002, REQ-RISK-003, REQ-RISK-004, REQ-RISK-005, REQ-RISK-007, REQ-RISK-008, REQ-RISK-039, REQ-RISK-040, REQ-RISK-053, REQ-RISK-054, REQ-RISK-055, REQ-RISK-072, REQ-RISK-095, Q-226, Q-229, Q-240, Q-259, Q-411
contract RiskModule is UUPSUpgradeable, AccessControlUpgradeable, RiskModuleSpeed, IRiskModule {
    /// @dev Drift, Hub shares and the expected collateral factor.
    address internal immutable _DRIFT_LOGIC;
    /// @dev Breaker conditions and states.
    address internal immutable _BREAKER_LOGIC;
    /// @dev The pledge check and its preview.
    address internal immutable _PLEDGE_LOGIC;
    /// @dev The borrow-side checks.
    address internal immutable _BORROW_LOGIC;
    /// @dev The account status.
    address internal immutable _STATUS_LOGIC;
    /// @dev The speed-limit reads.
    address internal immutable _SPEED_LOGIC;

    /// @notice Fixes the implementation immutables, checks each logic contract and disables initializers on the
    /// implementation itself.
    /// @param im The per-chain Avana addresses.
    /// @param logics The six logic contracts, each built with `im`.
    /// @custom:spec REQ-RISK-002
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
    /// @custom:spec REQ-RISK-002, REQ-RISK-072, Q-226, Q-228
    function initialize(
        address timelock
    ) external override initializer {
        if (timelock != _TIMELOCK) revert AdminRoleOnlyTimelock(DEFAULT_ADMIN_ROLE, timelock);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        _grantRole(AvanaRoles.APPLICATION_ADMIN, timelock);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Checks
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IRiskModuleChecks
    /// @dev After the pledge logic approves, a pledge that is not a rescue top-up is tested against the market's pledge
    /// window on its booked value before the pledge, `regularUsed + sliceUsed`; only Collateralization's call adds the
    /// charge (REQ-RISK-093, REQ-RISK-095).
    /// @custom:spec REQ-RISK-006, REQ-RISK-009, REQ-RISK-025, REQ-RISK-057, REQ-RISK-058, REQ-RISK-065, REQ-RISK-066, REQ-RISK-067, REQ-RISK-093, REQ-RISK-095, REQ-RISK-099
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
            _chargePledge(marketId, booked, charge.usdCharge, msg.sender == _COLLATERALIZATION);
        }
    }

    /// @inheritdoc IRiskModuleChecks
    /// @dev Every gate of the borrow logic first, then the two borrow-speed windows; only the AaveAdapter's call adds
    /// the charges (REQ-RISK-092, REQ-RISK-095).
    /// @custom:spec REQ-ADAPTER-009, REQ-ADAPTER-024, REQ-RISK-056, REQ-RISK-061, REQ-RISK-062, REQ-RISK-065, REQ-RISK-071, REQ-RISK-077, REQ-RISK-081, REQ-RISK-082, REQ-RISK-092, REQ-RISK-095, REQ-RISK-098
    function preBorrowCheck(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external override {
        IRiskModuleBorrowLogic(_BORROW_LOGIC).preCheck(proxy, debtReserveId, true);
        BorrowSpeedInputs memory s = IRiskModuleSpeedLogic(_SPEED_LOGIC).borrowInputs(proxy, debtReserveId, amount);
        _chargeBorrow(s, amount, msg.sender == _ADAPTER);
    }

    /// @inheritdoc IRiskModuleChecks
    /// @custom:spec REQ-ADAPTER-025, REQ-RISK-056, REQ-RISK-065, REQ-RISK-081
    function preWithdrawCheck(
        address proxy
    ) external override {
        IRiskModuleBorrowLogic(_BORROW_LOGIC).preCheck(proxy, type(uint256).max, false);
    }

    /// @inheritdoc IRiskModuleChecks
    /// @custom:spec REQ-ADAPTER-026, REQ-ADAPTER-027, REQ-RISK-059, REQ-RISK-068, SPEC-CF-005
    function postHealthCheck(
        address proxy,
        uint256 minHealthFactor
    ) external view override returns (uint256 healthFactor) {
        healthFactor = IRiskModuleBorrowLogic(_BORROW_LOGIC).postHealthCheck(proxy, minHealthFactor);
    }

    /// @inheritdoc IRiskModuleChecks
    /// @custom:spec REQ-ADAPTER-028, REQ-ADAPTER-036, REQ-RISK-063, REQ-RISK-069, REQ-RISK-076
    function checkAaveConfig(
        address spoke,
        uint256[] calldata marketIds
    ) external view override {
        (uint256 marketId, DriftReason reason) =
            IRiskModuleDriftLogic(_DRIFT_LOGIC).driftOf(spoke, marketIds, address(0));
        if (reason != DriftReason.None) revert ConfigDrift(marketId, reason);
    }

    /// @inheritdoc IRiskModuleChecks
    /// @custom:spec REQ-RISK-090, REQ-RISK-078, SPEC-BRK-008
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
            // The breach record of a permissionless poke, bounded by the Spoke's markets (REQ-RISK-090).
            // forge-lint: disable-next-line(calls-loop)
            _registry().recordBreach(bytes32(ids[i]), BreakerReasons.CONFIG_DRIFT);
        }
    }

    /// @inheritdoc IRiskModuleChecks
    /// @custom:spec REQ-RISK-091, SPEC-BRK-007, SPEC-BRK-008, Q-399
    function pokeBreakers(
        uint256 marketId
    ) external override returns (uint32 reasons) {
        Market memory m = _market(marketId);
        IRiskModuleBreakerLogic b = IRiskModuleBreakerLogic(_BREAKER_LOGIC);
        uint32 live = b.marketConditions(marketId, false, 0);
        if (live != 0) _registry().recordBreach(bytes32(marketId), live);
        reasons = live;
        uint256[] memory ids = _registry().getDebtReserveIds(m.spoke);
        for (uint256 i = 0; i < ids.length; ++i) {
            // Debt reserves of the market's Spoke, bounded by the timelock's listings (REQ-RISK-091).
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
    /// @custom:spec REQ-ADAPTER-037, Q-189
    function isHubSharesEqualAssets(
        uint256 marketId
    ) external view override returns (bool equal) {
        equal = IRiskModuleDriftLogic(_DRIFT_LOGIC).isHubSharesEqualAssets(marketId);
    }

    /// @inheritdoc IRiskModuleChecks
    /// @custom:spec REQ-RISK-070, REQ-RISK-075, WDR-031
    function checkRemainingRecord(
        uint256 marketId,
        uint128 remainingUnits
    ) external view override {
        IRiskModulePledgeLogic(_PLEDGE_LOGIC).checkRemainingRecord(marketId, remainingUnits);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IRiskModuleViews
    /// @dev Never reverts: a failure of the preview body is reported as `eligible = false` with its selector.
    /// @custom:spec REQ-RISK-031, REQ-RISK-057
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
    /// @dev Never reverts. The status body reads no pause state; the pause state and reason of the market's Hub come
    /// from `pauseOf` and are copied into `pauseState` and `pauseReason` only, so no other field depends on them. A
    /// revert of either call returns the unavailable status (`_unavailable`).
    /// @custom:spec REQ-ADAPTER-038, REQ-RISK-060
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

    /// @dev The status when it cannot be computed (REQ-ADAPTER-038): `statusUnavailable`, every reserve field at the
    /// no-reserve value `type(uint256).max` (reserve 0 is a valid identifier), nothing allowed, every other field zero.
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
    /// @custom:spec SPEC-CAP-003
    function usdToRestore(
        address proxy
    ) external view override returns (uint256 usd) {
        usd = IRiskModulePledgeLogic(_PLEDGE_LOGIC).usdToRestore(proxy);
    }

    /// @inheritdoc IRiskModuleViews
    /// @custom:spec SPEC-CF-001
    function expectedCollateralFactorBps(
        uint256 marketId
    ) external view override returns (uint256 cfBps) {
        cfBps = IRiskModuleDriftLogic(_DRIFT_LOGIC).expectedCollateralFactorBps(marketId);
    }

    /// @inheritdoc IRiskModuleViews
    /// @dev Never reverts: a failed evaluation reports every temporary and security reason, with no reopening time.
    /// @custom:spec REQ-RISK-065, REQ-RISK-078, SPEC-BRK-007, Q-399
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
    /// @dev Never reverts: a failed evaluation reports every temporary and security reason, with no reopening time.
    /// @custom:spec REQ-RISK-065, SPEC-BRK-004, SPEC-BRK-007, Q-399
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
    /// @custom:spec REQ-MREG-025, SPEC-BRK-008, Q-399
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
    /// @custom:spec REQ-MREG-025, SPEC-BRK-008, Q-399
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
    /// @custom:spec SPEC-CAP-009, REQ-RISK-077
    function debtValueUsd(
        address proxy
    ) external view override returns (uint256 usd) {
        usd = IRiskModuleBorrowLogic(_BORROW_LOGIC).debtValueUsd(proxy);
    }

    /// @inheritdoc IRiskModuleViews
    /// @custom:spec REQ-RISK-097, SPEC-CAP-011, Q-411
    function getBorrowSpeed(
        uint256 marketId,
        uint256 debtReserveId
    ) external view override returns (SpeedView memory market, SpeedView memory debt) {
        try IRiskModuleSpeedLogic(_SPEED_LOGIC).borrowInputsOf(marketId, debtReserveId) returns (
            BorrowSpeedInputs memory s
        ) {
            (market, debt) = _borrowViews(s);
        } catch {
            (market.unavailable, debt.unavailable) = (true, true);
        }
    }

    /// @inheritdoc IRiskModuleViews
    /// @custom:spec REQ-RISK-097, SPEC-CAP-011, Q-411
    function getPledgeSpeed(
        uint256 marketId
    ) external view override returns (SpeedView memory pledge) {
        try IRiskModuleSpeedLogic(_SPEED_LOGIC).pledgeInputsOf(marketId) returns (
            MarketSpeedLimits memory p, uint256 booked
        ) {
            pledge = _pledgeView(marketId, p, booked);
        } catch {
            pledge.unavailable = true;
        }
    }

    /// @inheritdoc IRiskModuleViews
    /// @custom:spec REQ-RISK-059, SPEC-PROXY-001, SPEC-CAP-003, Q-398
    function rescueHealthFactor() external pure override returns (uint256 value) {
        value = RiskModuleConstants.RESCUE_HEALTH_FACTOR;
    }

    /// @inheritdoc IRiskModuleViews
    /// @custom:spec REQ-RISK-067, Q-252
    function RESCUE_MIN_PLEDGE_USD() external pure override returns (uint256 usd) {
        usd = RiskModuleConstants.RESCUE_MIN_PLEDGE_USD;
    }

    /// @inheritdoc IRiskModuleViews
    /// @custom:spec REQ-RISK-029, REQ-RISK-055
    function MARKET_REGISTRY() external view override returns (address marketRegistry) {
        marketRegistry = _MARKET_REGISTRY;
    }

    /// @inheritdoc IRiskModuleViews
    /// @custom:spec REQ-RISK-055
    function PARAMETER_STORE() external view override returns (address parameterStore) {
        parameterStore = _PARAMETER_STORE;
    }

    /// @inheritdoc IRiskModuleViews
    /// @custom:spec REQ-RISK-004, REQ-RISK-058
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc IRiskModuleViews
    /// @custom:spec REQ-ADAPTER-009, REQ-RISK-031
    function ADAPTER() external view override returns (address adapter) {
        adapter = _ADAPTER;
    }

    /// @inheritdoc IRiskModuleViews
    /// @custom:spec REQ-RISK-071
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc IRiskModuleViews
    /// @custom:spec REQ-RISK-072, Q-259
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _TIMELOCK;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Roles and upgrades
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Either admin role can be held only by `TIMELOCK`, through `initialize` or any later grant.
    /// @custom:spec REQ-RISK-072, REQ-ACCESS-153, Q-259
    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        if ((role == DEFAULT_ADMIN_ROLE || role == AvanaRoles.APPLICATION_ADMIN) && account != _TIMELOCK) {
            revert AdminRoleOnlyTimelock(role, account);
        }
        granted = super._grantRole(role, account);
    }

    /// @dev Upgrades need `APPLICATION_ADMIN`, held only by the timelock (normal delay).
    /// @custom:spec REQ-RISK-002
    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}
}
