// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {PriceState} from "../../types/PriceState.sol";
import {RouteSlot} from "../../types/RouteSlot.sol";
import {LPPriceMath} from "../lp-oracle/LPPriceMath.sol";
import {DebtOracleRecovery} from "./DebtOracleRecovery.sol";
import {IDebtOracle} from "./IDebtOracle.sol";
import {DebtEvaluation, LegRead, ReadStatus, RouteRead} from "./types/DebtEvaluation.sol";
import {DebtOracleInitParams} from "./types/DebtOracleInitParams.sol";
import {DebtPriceView} from "./types/DebtPriceView.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title DebtOracle
/// @notice Price source of one debt asset with a market price (USDC, USDT, WETH): the USD price of one whole token with
/// 8 decimals for the AaveOracle of every CDP Spoke on the chain that lends it, and the price state, timestamps and age
/// limits the RiskModule and LPVaultSwap enforce their debt gates from. GHO keeps Aave's fixed source.
/// @dev UUPS implementation behind one ERC-1967 proxy per debt asset per chain; `_authorizeUpgrade` requires
/// `APPLICATION_ADMIN`, held only by `TIMELOCK`. It applies the LPOracle's leg, route, failover, agreement, freshness,
/// second-source, sequencer and timer rules to one token, with no pool, band or ceiling. Invariants every function
/// preserves: solvency (a debt price that cannot be trusted is never below the accepted price and never admits new
/// debt); `latestAnswer() >= 1` and no revert except `InsufficientGas`; only `poke()` writes price, timer, latch, `seen`
/// or route-version storage; no role can push a price; no token, ETH or approval moves through it.
/// Example: USDC accepted at 99,990,000 ($0.9999) with `debtStressRiseBps = 500` serves 99,990,000 while Cached and
/// 104,989,500 once Expired.
/// @custom:spec REQ-ORACLE-091, REQ-ORACLE-092, REQ-ORACLE-093, REQ-ORACLE-096, REQ-ORACLE-097, REQ-ORACLE-098, SPEC-ORC-018, INV-087, Q-238, Q-247, Q-248, Q-259
contract DebtOracle is UUPSUpgradeable, AccessControlUpgradeable, DebtOracleRecovery, IDebtOracle {
    /// @dev The chain's AvanaTimelock, the only account that may hold `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN`.
    address internal immutable _TIMELOCK;

    /// @dev The largest `int256`, as an unsigned value.
    uint256 private constant _INT256_MAX = 2 ** 255 - 1;

    /// @notice Fixes `TIMELOCK` and disables initializers on the implementation.
    /// @param timelock The chain's AvanaTimelock.
    /// @custom:spec REQ-ORACLE-097, REQ-ORACLE-080
    constructor(
        address timelock
    ) {
        if (timelock == address(0)) revert AdminRoleOnlyTimelock(DEFAULT_ADMIN_ROLE, timelock);
        _TIMELOCK = timelock;
        _disableInitializers();
    }

    // Every external call of this contract is a gas-guarded static call (REQ-ORACLE-098): no callee can reenter or
    // change state, so emitting events after those reads cannot be exploited.
    // forge-lint: disable-start(reentrancy-events)

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-091, REQ-ORACLE-097, REQ-ORACLE-031, REQ-ORACLE-058
    function initialize(
        DebtOracleInitParams calldata params
    ) external override initializer {
        if (params.timelock != _TIMELOCK) revert AdminRoleOnlyTimelock(DEFAULT_ADMIN_ROLE, params.timelock);
        if (!_readListed(params.marketRegistry, params.asset)) revert NotDebtAsset(params.asset);
        (bool routesOk,,) = _readRouteFeeds(params.marketRegistry, params.asset);
        if (!routesOk) revert NotDebtAsset(params.asset);
        _checkPokeMinGas(params.pokeMinGas);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, params.timelock);
        _grantRole(AvanaRoles.APPLICATION_ADMIN, params.timelock);
        DebtOracleLayout storage $ = _s();
        $.asset = params.asset;
        $.marketRegistry = params.marketRegistry;
        $.parameterStore = params.parameterStore;
        $.descriptionText = params.description;
        $.pokeMinGas = params.pokeMinGas;
        DebtEvaluation memory e = _evaluate();
        if (e.state != PriceState.Live) revert NotLive(uint8(e.state), e.reasons);
        $.accepted = Accepted({price8: SafeCast.toUint128(e.quote), updatedAt: e.quoteUpdatedAt});
        $.routeVersion = e.routeVersion;
        $.lastRoute = uint8(e.routeUsed);
        $.lastCachedWindow = e.cachedWindow;
        $.lastStressRiseBps = e.stressRiseBps;
        _recordSeen($, e);
        emit DebtPriceSeeded(e.quote, e.quoteUpdatedAt);
    }

    // ─── Served price ───

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-093, SPEC-ORC-018, REQ-ORACLE-060, REQ-ORACLE-061
    function latestAnswer() external view override(IDebtOracle) returns (int256 answer) {
        return _answer(_evaluate().served);
    }

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-091, REQ-ORACLE-040
    function decimals() external pure override(IDebtOracle) returns (uint8) {
        return LPPriceMath.DECIMALS;
    }

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-091, REQ-ORACLE-040
    function description() external view override(IDebtOracle) returns (string memory) {
        return _s().descriptionText;
    }

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-093, REQ-ORACLE-041
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        DebtEvaluation memory e = _evaluate();
        roundId = uint80(e.servedUpdatedAt);
        answer = _answer(e.served);
        startedAt = e.servedUpdatedAt;
        updatedAt = e.servedUpdatedAt;
        answeredInRound = roundId;
    }

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-093, REQ-ORACLE-092, REQ-ORACLE-090, REQ-ORACLE-042, REQ-ORACLE-045
    function getPriceState() external view override returns (DebtPriceView memory report) {
        return _report(_evaluate());
    }

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-093, REQ-ORACLE-087
    function lastAcceptedPrice() external view override returns (uint256 price8, uint64 updatedAt) {
        Accepted storage a = _s().accepted;
        return (a.price8, a.updatedAt);
    }

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-093, SPEC-ORC-015, REQ-ORACLE-043
    function borrowPriceMaxAge() external view override returns (uint32 age) {
        return _evaluate().borrowPriceMaxAge;
    }

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-093, REQ-ORACLE-090, SPEC-ORC-015, REQ-ORACLE-043
    function liquidationPriceMaxAge() external view override returns (uint32 age) {
        return _evaluate().liquidationPriceMaxAge;
    }

    // ─── Writing call ───

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-024, REQ-ORACLE-025, REQ-ORACLE-026, REQ-ORACLE-027, REQ-ORACLE-028, REQ-ORACLE-029, REQ-ORACLE-030, REQ-ORACLE-031, REQ-ORACLE-032, REQ-ORACLE-035, REQ-ORACLE-089, REQ-ORACLE-095
    function poke() external override returns (PriceState state) {
        DebtOracleLayout storage $ = _s();
        uint256 minGas = $.pokeMinGas;
        if (gasleft() < minGas) revert InsufficientGas(gasleft(), minGas);
        DebtEvaluation memory e = _evaluate();
        bool versionChanged = e.routeVersionRead && e.routeVersion != $.routeVersion;
        bool evidence = false;
        uint64 recovered = 0;
        if (!e.failed) (evidence, recovered) = _evidence(e);
        if (versionChanged) {
            emit DebtRouteVersionObserved($.routeVersion, e.routeVersion);
            $.routeVersion = e.routeVersion;
        }
        _applyFailure($, e);
        _applyDisagreement($, e, versionChanged);
        if (e.state == PriceState.Live && e.quoteUpdatedAt > $.accepted.updatedAt) {
            $.accepted = Accepted({price8: SafeCast.toUint128(e.quote), updatedAt: e.quoteUpdatedAt});
            emit DebtPriceAccepted(e.quote, e.quoteUpdatedAt, e.routeUsed);
        }
        if (e.sourceTimestampFailure && !$.expiredLatched && block.timestamp >= uint256(e.staleAt) + e.cachedWindow) {
            $.expiredLatched = true;
            emit DebtOutageExpiredLatched(e.staleAt, SafeCast.toUint64(block.timestamp));
        }
        _recordSeen($, e);
        if (e.cachedWindowRead && e.cachedWindow != $.lastCachedWindow) $.lastCachedWindow = e.cachedWindow;
        if (e.stressRiseRead && e.stressRiseBps != $.lastStressRiseBps) $.lastStressRiseBps = e.stressRiseBps;
        if (!e.failed && ($.expiredLatched || evidence)) _startGrace($, e, versionChanged, evidence, recovered);
        _emitStateAndRoute($, e);
        return e.state;
    }

    // ─── Governance ───

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-098, REQ-ORACLE-038
    function setPokeMinGas(
        uint32 value
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _checkPokeMinGas(value);
        DebtOracleLayout storage $ = _s();
        uint32 previous = $.pokeMinGas;
        $.pokeMinGas = value;
        emit PokeMinGasUpdated(previous, value);
    }

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-098
    function pokeMinGas() external view override returns (uint32 value) {
        return _s().pokeMinGas;
    }

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-091
    function ASSET() external view override returns (address asset) {
        return _s().asset;
    }

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-091, REQ-ORACLE-094
    function MARKET_REGISTRY() external view override returns (address registry) {
        return _s().marketRegistry;
    }

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-091
    function PARAMETER_STORE() external view override returns (address store) {
        return _s().parameterStore;
    }

    /// @inheritdoc IDebtOracle
    /// @custom:spec REQ-ORACLE-097
    function TIMELOCK() external view override returns (address timelock) {
        return _TIMELOCK;
    }

    // ─── Internal ───

    /// @dev `REQ-ORACLE-027` and `REQ-ORACLE-028`'s failure half: set on the first failed poke from the source
    /// timestamps (never later than now), cleared on the first poke that sees the asset not failed.
    /// @custom:spec REQ-ORACLE-027, SPEC-ORC-013
    function _applyFailure(
        DebtOracleLayout storage $,
        DebtEvaluation memory e
    ) internal {
        uint64 failedSince = $.failedSince;
        if (e.failed && failedSince == 0) {
            uint64 at = SafeCast.toUint64(block.timestamp);
            if (e.sourceTimestampFailure && e.staleAt < at) at = e.staleAt;
            $.failedSince = at;
            emit DebtFailureRecorded(at, e.reasons);
        } else if (!e.failed && failedSince != 0) {
            $.failedSince = 0;
            emit DebtFailureCleared(failedSince, SafeCast.toUint64(block.timestamp));
        }
    }

    /// @dev `REQ-ORACLE-028` with `REQ-ORACLE-095`: the first observation of a disagreement, restarted by a route-version
    /// change, cleared when the routes agree or the asset is failed.
    /// @custom:spec REQ-ORACLE-028, REQ-ORACLE-095, REQ-ORACLE-023
    function _applyDisagreement(
        DebtOracleLayout storage $,
        DebtEvaluation memory e,
        bool versionChanged
    ) internal {
        uint64 stored = $.disagreeSince;
        if (e.disagree && !e.failed) {
            if (stored == 0 || versionChanged) {
                uint64 nowTs = SafeCast.toUint64(block.timestamp);
                $.disagreeSince = nowTs;
                emit DebtDisagreementRecorded(nowTs, e.routes[0].value, e.routes[1].value);
            }
        } else if (stored != 0) {
            $.disagreeSince = 0;
            emit DebtDisagreementCleared(stored, SafeCast.toUint64(block.timestamp));
        }
    }

    /// @dev `REQ-ORACLE-032`: (a) a version change observed while latched starts at now; (b) otherwise the
    /// source-timestamp evidence; (c) otherwise the newest leg in use, never after now. Clears the latch.
    /// @custom:spec REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-065
    function _startGrace(
        DebtOracleLayout storage $,
        DebtEvaluation memory e,
        bool versionChanged,
        bool evidence,
        uint64 recovered
    ) internal {
        bool latched = $.expiredLatched;
        uint64 rec = 0;
        bool fromLatch = true;
        if (latched && versionChanged) {
            rec = SafeCast.toUint64(block.timestamp);
        } else if (evidence) {
            rec = recovered;
            fromLatch = false;
        } else {
            RouteRead memory route = e.routes[e.routeUsed == RouteSlot.Primary ? 0 : 1];
            for (uint256 j = 0; j < route.legCount; ++j) {
                if (route.legs[j].updatedAt > rec) rec = route.legs[j].updatedAt;
            }
            if (rec > block.timestamp) rec = SafeCast.toUint64(block.timestamp);
        }
        $.recoveredAt = rec;
        $.expiredLatched = false;
        emit DebtGraceStarted(rec, rec + e.graceDuration, fromLatch);
    }

    /// @dev `REQ-ORACLE-031`: every leg whose read decoded records its aggregator, round and timestamp; legs that did
    /// not decode keep their previous record.
    /// @custom:spec REQ-ORACLE-031
    function _recordSeen(
        DebtOracleLayout storage $,
        DebtEvaluation memory e
    ) internal {
        _recordLeg($.seen[0][0], e.routes[0], 0);
        _recordLeg($.seen[0][1], e.routes[0], 1);
        _recordLeg($.seen[1][0], e.routes[1], 0);
        _recordLeg($.seen[1][1], e.routes[1], 1);
    }

    /// @dev Writes one `seen` entry when the leg exists in the route and decoded.
    function _recordLeg(
        Seen storage seen,
        RouteRead memory route,
        uint256 j
    ) internal {
        if (j >= route.legCount) return;
        LegRead memory leg = route.legs[j];
        if (leg.status == ReadStatus.Error) return;
        seen.feed = leg.feed;
        seen.roundId = leg.roundId;
        seen.updatedAt = leg.updatedAt;
    }

    /// @dev `REQ-ORACLE-035`: state and route-used events against the last writing call, then the new values.
    /// @custom:spec REQ-ORACLE-035
    function _emitStateAndRoute(
        DebtOracleLayout storage $,
        DebtEvaluation memory e
    ) internal {
        uint8 last = $.lastState;
        if (uint8(e.state) != last) {
            emit DebtPriceStateChanged(PriceState(last), e.state, e.reasons);
            $.lastState = uint8(e.state);
        }
        uint8 lastRoute = $.lastRoute;
        if (uint8(e.routeUsed) != lastRoute) {
            emit DebtRouteChanged(RouteSlot(lastRoute), e.routeUsed);
            $.lastRoute = uint8(e.routeUsed);
        }
    }

    // forge-lint: disable-end(reentrancy-events)

    /// @dev `PokeMinGasOutOfBounds` outside `[POKE_MIN_GAS_FLOOR, POKE_MIN_GAS_CEILING]`.
    /// @custom:spec REQ-ORACLE-038, REQ-ORACLE-098
    function _checkPokeMinGas(
        uint32 value
    ) internal pure {
        if (value < POKE_MIN_GAS_FLOOR_VALUE || value > POKE_MIN_GAS_CEILING_VALUE) {
            revert PokeMinGasOutOfBounds(value);
        }
    }

    /// @dev The served price as Aave's `int256`; it is at most `1.5 * MAX_ROUTE_ANSWER + 1`, and saturation only
    /// guards the conversion.
    function _answer(
        uint256 served
    ) internal pure returns (int256) {
        return SafeCast.toInt256(Math.min(served, _INT256_MAX));
    }

    /// @dev Builds the `DebtPriceView` of one evaluation.
    /// @custom:spec REQ-ORACLE-093, REQ-ORACLE-042
    function _report(
        DebtEvaluation memory e
    ) internal view returns (DebtPriceView memory v) {
        v.state = e.state;
        v.reasons = e.reasons;
        v.answer = _answer(e.served);
        v.servedUpdatedAt = e.servedUpdatedAt;
        v.servedAge = SafeCast.toUint64(block.timestamp - e.servedUpdatedAt);
        v.acceptedAnswer = e.accepted;
        v.acceptedUpdatedAt = e.acceptedUpdatedAt;
        v.routeUsed = e.routeUsed;
        v.quote = e.failed ? 0 : e.quote;
        (v.primaryValue, v.primaryAge) = _routeValueAge(e.routes[0]);
        (v.alternateValue, v.alternateAge) = _routeValueAge(e.routes[1]);
        v.deviationBps = LPPriceMath.deviationBps(v.primaryValue, v.alternateValue);
        v.feedAgreementToleranceBps = e.toleranceBps;
        v.replaced = e.replaced;
        v.routeVersion = e.routeVersion;
        if (e.servedRoute != RouteSlot.None) _reportLegs(v, e);
        if (e.failed) {
            v.failureStart = e.failureStart;
            v.cachedUntil = e.failureStart + e.cachedWindow;
        }
        v.disagreeSince = e.disagreeSince;
        v.disagreementPauseActive = e.pauseActive;
        v.disagreementExpired = e.disagreementExpired;
        v.liquidationPaused = e.liquidationPaused;
        v.recoveredAt = e.recoveredAt;
        v.graceEndsAt = e.graceEndsAt;
        v.inGrace = e.inGrace;
        v.borrowPriceMaxAge = e.borrowPriceMaxAge;
        v.liquidationPriceMaxAge = e.liquidationPriceMaxAge;
        v.debtStressRiseBps = e.stressRiseBps;
        v.stressAnswer = LPPriceMath.debtServedPrice(PriceState.Expired, 0, 0, 0, e.accepted, e.stressRiseBps);
        v.borrowAllowed = e.borrowAllowed;
    }

    /// @dev Feeds, timestamps and age limits of the legs of the served route (`_servedRoute`).
    function _reportLegs(
        DebtPriceView memory v,
        DebtEvaluation memory e
    ) internal pure {
        bool onAlternate = e.servedRoute == RouteSlot.Alternate;
        RouteRead memory route = e.routes[onAlternate ? 1 : 0];
        for (uint256 j = 0; j < route.legCount; ++j) {
            LegRead memory leg = route.legs[j];
            v.legFeeds[j] = leg.feed;
            v.legUpdatedAt[j] = leg.updatedAt;
            v.legBorrowPriceMaxAge[j] = leg.borrowMaxAge;
            v.legLiquidationPriceMaxAge[j] =
                onAlternate && leg.borrowMaxAge < leg.liquidationMaxAge ? leg.borrowMaxAge : leg.liquidationMaxAge;
        }
    }

    /// @dev A route's value and age, or 0 and `type(uint64).max` when it was not read or a leg did not decode.
    function _routeValueAge(
        RouteRead memory route
    ) internal view returns (uint256 value, uint64 age) {
        if (route.legCount == 0 || route.updatedAt == 0 || route.updatedAt > block.timestamp) {
            return (route.value, type(uint64).max);
        }
        return (route.value, SafeCast.toUint64(block.timestamp - route.updatedAt));
    }

    /// @dev Either admin role can be held only by `TIMELOCK`, through `initialize` or any later grant.
    /// @custom:spec REQ-ORACLE-097, Q-259
    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        if ((role == DEFAULT_ADMIN_ROLE || role == AvanaRoles.APPLICATION_ADMIN) && account != _TIMELOCK) {
            revert AdminRoleOnlyTimelock(role, account);
        }
        granted = super._grantRole(role, account);
    }

    /// @dev Upgrades require `APPLICATION_ADMIN`, held only by the timelock (normal delay).
    /// @custom:spec REQ-ORACLE-091, REQ-ORACLE-078
    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}
}
