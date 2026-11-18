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
/// @notice Price source of one debt asset with a market price: the USD price of one whole token, with 8 decimals.
/// @dev UUPS proxy; only the timelock can upgrade it.
contract DebtOracle is UUPSUpgradeable, AccessControlUpgradeable, DebtOracleRecovery, IDebtOracle {
    address internal immutable _TIMELOCK;

    uint256 private constant _INT256_MAX = 2 ** 255 - 1;

    constructor(
        address timelock
    ) {
        if (timelock == address(0)) revert AdminRoleOnlyTimelock(DEFAULT_ADMIN_ROLE, timelock);
        _TIMELOCK = timelock;
        _disableInitializers();
    }

    // Every external call is a gas-guarded static call, so no callee can reenter or change state.
    // forge-lint: disable-start(reentrancy-events)

    /// @inheritdoc IDebtOracle
    function initialize(
        DebtOracleInitParams calldata params
    ) external override initializer {
        if (params.timelock != _TIMELOCK) revert AdminRoleOnlyTimelock(DEFAULT_ADMIN_ROLE, params.timelock);
        if (!_readListed(params.marketRegistry, params.asset) || !_routesReadable(params.marketRegistry, params.asset))
        {
            revert NotDebtAsset(params.asset);
        }
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
        _accept($, e);
        $.routeVersion = e.routeVersion;
        $.lastRoute = uint8(e.routeUsed);
        $.lastCachedWindow = e.cachedWindow;
        $.lastStressRiseBps = e.stressRiseBps;
        _recordSeen($, e);
        emit DebtPriceSeeded(e.quote, e.quoteUpdatedAt);
    }

    /// @inheritdoc IDebtOracle
    function latestAnswer() external view override(IDebtOracle) returns (int256 answer) {
        return _answer(_evaluate().served);
    }

    /// @inheritdoc IDebtOracle
    function decimals() external pure override(IDebtOracle) returns (uint8) {
        return LPPriceMath.DECIMALS;
    }

    /// @inheritdoc IDebtOracle
    function description() external view override(IDebtOracle) returns (string memory) {
        return _s().descriptionText;
    }

    /// @inheritdoc IDebtOracle
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
    function getPriceState() external view override returns (DebtPriceView memory report) {
        return _report(_evaluate());
    }

    /// @inheritdoc IDebtOracle
    function lastAcceptedPrice() external view override returns (uint256 price8, uint64 updatedAt) {
        Accepted storage a = _s().accepted;
        return (a.price8, a.updatedAt);
    }

    /// @inheritdoc IDebtOracle
    function borrowPriceMaxAge() external view override returns (uint32 age) {
        return _evaluate().borrowPriceMaxAge;
    }

    /// @inheritdoc IDebtOracle
    function liquidationPriceMaxAge() external view override returns (uint32 age) {
        return _evaluate().liquidationPriceMaxAge;
    }

    /// @inheritdoc IDebtOracle
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
            _accept($, e);
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

    /// @inheritdoc IDebtOracle
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
    function pokeMinGas() external view override returns (uint32 value) {
        return _s().pokeMinGas;
    }

    /// @inheritdoc IDebtOracle
    function ASSET() external view override returns (address asset) {
        return _s().asset;
    }

    /// @inheritdoc IDebtOracle
    function MARKET_REGISTRY() external view override returns (address registry) {
        return _s().marketRegistry;
    }

    /// @inheritdoc IDebtOracle
    function PARAMETER_STORE() external view override returns (address store) {
        return _s().parameterStore;
    }

    /// @inheritdoc IDebtOracle
    function TIMELOCK() external view override returns (address timelock) {
        return _TIMELOCK;
    }

    /// @dev Sets `failedSince` on the first failed poke, never after now; clears it on recovery.
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

    /// @dev Sets `disagreeSince` on a new disagreement or route-version change; clears it on agreement or failure.
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

    function _accept(
        DebtOracleLayout storage $,
        DebtEvaluation memory e
    ) internal {
        $.accepted = Accepted({price8: SafeCast.toUint128(e.quote), updatedAt: e.quoteUpdatedAt});
    }

    function _routesReadable(
        address registry,
        address asset
    ) internal view returns (bool ok) {
        (ok,,) = _readRouteFeeds(registry, asset);
    }

    /// @dev Records each decoded leg; skipped when the config read failed, since no leg was read.
    function _recordSeen(
        DebtOracleLayout storage $,
        DebtEvaluation memory e
    ) internal {
        if ((e.reasons & R_CONFIG_UNAVAILABLE) != 0) return;
        _recordLeg($.seen[0][0], e.routes[0], 0);
        _recordLeg($.seen[0][1], e.routes[0], 1);
        _recordLeg($.seen[1][0], e.routes[1], 0);
        _recordLeg($.seen[1][1], e.routes[1], 1);
    }

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

    function _checkPokeMinGas(
        uint32 value
    ) internal pure {
        if (value < POKE_MIN_GAS_FLOOR_VALUE || value > POKE_MIN_GAS_CEILING_VALUE) {
            revert PokeMinGasOutOfBounds(value);
        }
    }

    function _answer(
        uint256 served
    ) internal pure returns (int256) {
        return SafeCast.toInt256(Math.min(served, _INT256_MAX));
    }

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

    /// @dev A route's value and age, or 0 and `type(uint64).max` when it was not read.
    function _routeValueAge(
        RouteRead memory route
    ) internal view returns (uint256 value, uint64 age) {
        if (route.legCount == 0 || route.updatedAt == 0 || route.updatedAt > block.timestamp) {
            return (route.value, type(uint64).max);
        }
        return (route.value, SafeCast.toUint64(block.timestamp - route.updatedAt));
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

    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}
}
