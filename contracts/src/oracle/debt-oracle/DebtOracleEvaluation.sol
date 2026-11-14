// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryStandby} from "../../policy/market-registry/IMarketRegistryStandby.sol";
import {IMarketRegistryViews} from "../../policy/market-registry/IMarketRegistryViews.sol";
import {IParameterStoreChain} from "../../policy/parameter-store/IParameterStoreChain.sol";
import {IParameterStoreLiquidation} from "../../policy/parameter-store/IParameterStoreLiquidation.sol";
import {IParameterStoreViews} from "../../policy/parameter-store/IParameterStoreViews.sol";
import {PriceState} from "../../types/PriceState.sol";
import {RouteSlot} from "../../types/RouteSlot.sol";
import {SecondSourceKind} from "../../types/SecondSourceKind.sol";
import {LPPriceMath} from "../lp-oracle/LPPriceMath.sol";
import {DebtOracleReads} from "./DebtOracleReads.sol";
import {DebtEvaluation, LegRead, ReadStatus, RouteRead} from "./types/DebtEvaluation.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title DebtOracleEvaluation
/// @notice One evaluation of the debt asset: configuration, legs, routes, quote and failover, agreement, state,
/// failure start, disagreement windows, served price and its age limits, sequencer gate, grace and second source.
/// @dev Shared by every view and `poke()`, so `getPriceState().answer == latestAnswer()` in the same block. It reads
/// storage and makes only gas-guarded static calls; it never writes and never reverts except `InsufficientGas`.
/// @custom:spec REQ-ORACLE-092, REQ-ORACLE-093, REQ-ORACLE-094, REQ-ORACLE-095, SPEC-ORC-013, SPEC-ORC-015, SPEC-ORC-016, SPEC-ORC-018, SPEC-ORC-020, SPEC-ORC-021
abstract contract DebtOracleEvaluation is DebtOracleReads {
    /// @dev Evaluates the asset in the current block.
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-093, REQ-ORACLE-016, REQ-ORACLE-026
    function _evaluate() internal view returns (DebtEvaluation memory e) {
        DebtOracleLayout storage $ = _s();
        e.accepted = $.accepted.price8;
        e.acceptedUpdatedAt = $.accepted.updatedAt;
        e.recoveredAt = $.recoveredAt;
        bool configOk = _readConfig($, e);
        if (configOk) {
            _readRoute(e.routes[0]);
            _readRoute(e.routes[1]);
        }
        _classify($, e, configOk);
        if (!e.failed) _readSecondSource($, e);
        _serve(e);
        _readSequencer($.parameterStore, e);
        _grace(e);
        e.liquidationPaused = e.state != PriceState.Live || e.alternatePastBorrowAge || e.sequencerDown;
        e.borrowAllowed = e.state == PriceState.Live && e.sequencerReady && e.confirmed
            && block.timestamp - e.servedUpdatedAt <= e.borrowPriceMaxAge;
    }

    /// @dev Every configuration read of `REQ-ORACLE-092`; false when one fails (reason bit 2). A failed `cachedWindow`
    /// read uses `lastCachedWindow` and a failed `debtStressRiseBps` read `lastStressRiseBps`, the values the last
    /// writing call read. A stress rise above `MAX_STRESS_RISE_BPS` is read as 5,000 (`SPEC-ORC-018`).
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-094, REQ-ORACLE-017, REQ-ORACLE-083
    function _readConfig(
        DebtOracleLayout storage $,
        DebtEvaluation memory e
    ) internal view returns (bool ok) {
        address store = $.parameterStore;
        address registry = $.marketRegistry;
        address asset = $.asset;
        uint256 v;
        bool r;
        ok = true;
        (r, v) = _readWord(store, IParameterStoreViews.cachedWindow.selector, type(uint32).max);
        ok = ok && r;
        e.cachedWindowRead = r;
        e.cachedWindow = r ? SafeCast.toUint32(v) : $.lastCachedWindow;
        (r, v) = _readWordOf(store, IParameterStoreLiquidation.debtStressRiseBps.selector, asset, type(uint16).max);
        ok = ok && r;
        e.stressRiseRead = r;
        e.stressRiseBps = r ? SafeCast.toUint16(Math.min(v, MAX_STRESS_RISE_BPS)) : $.lastStressRiseBps;
        (r, v) = _readWord(store, IParameterStoreViews.disagreementPauseMax.selector, type(uint32).max);
        ok = ok && r;
        e.disagreementPauseMax = SafeCast.toUint32(v);
        (r, v) = _readWord(store, IParameterStoreViews.graceDuration.selector, type(uint32).max);
        ok = ok && r;
        e.graceDuration = SafeCast.toUint32(v);
        (r, v) = _readWordOf(store, IParameterStoreViews.feedAgreementToleranceBps.selector, asset, type(uint16).max);
        ok = ok && r;
        e.toleranceBps = SafeCast.toUint16(v);
        (r, v) = _readWordOf(registry, IMarketRegistryStandby.priceRouteVersion.selector, asset, type(uint64).max);
        e.routeVersionRead = r;
        e.routeVersion = SafeCast.toUint64(v);
        ok = ok && r && _readListed(registry, asset);
        if (!ok) return false;
        (ok, e.replaced, e.routes) = _readRouteFeeds(registry, asset);
        if (!ok) return false;
        for (uint256 i = 0; i < 2; ++i) {
            RouteRead memory route = e.routes[i];
            for (uint256 j = 0; j < route.legCount; ++j) {
                if (!_readFeedDef(store, route.legs[j])) return false;
            }
        }
    }

    /// @dev `MarketRegistry.getToken(asset).listed`: the return is an offset word (32) and the struct, whose first word
    /// is `listed`.
    /// @custom:spec REQ-ORACLE-091, REQ-ORACLE-092
    function _readListed(
        address registry,
        address asset
    ) internal view returns (bool listed) {
        (bool s,, uint256[] memory w) = _callOf(registry, IMarketRegistryViews.getToken.selector, asset, 2);
        return s && w.length == 2 && w[0] == 32 && w[1] == 1;
    }

    /// @dev `MarketRegistry.activePriceRoutes(asset)` in its canonical encoding: two arrays of one or two aggregator
    /// addresses each and the replaced slot. Any other shape (no leg, more than two legs, another layout) fails.
    /// @custom:spec REQ-ORACLE-094, REQ-ORACLE-017
    function _readRouteFeeds(
        address registry,
        address asset
    ) internal view returns (bool ok, RouteSlot replaced, RouteRead[2] memory routes) {
        (bool s, uint256 size, uint256[] memory w) =
            _callOf(registry, IMarketRegistryStandby.activePriceRoutes.selector, asset, 9);
        if (!s || (size & 31) != 0 || size > 288 || w.length < 5 || w[0] != 96 || w[2] > 2) {
            return (false, replaced, routes);
        }
        uint256 n0 = w[3];
        if (n0 < 1 || n0 > 2 || w[1] != 32 * (4 + n0)) return (false, replaced, routes);
        uint256 n1 = w[4 + n0];
        if (n1 < 1 || n1 > 2 || w.length != 5 + n0 + n1) return (false, replaced, routes);
        replaced = RouteSlot(w[2]);
        ok = _setFeeds(routes[0], w, 4, n0) && _setFeeds(routes[1], w, 5 + n0, n1);
    }

    /// @dev Copies `n` aggregator words from `w[first..]` into a route.
    function _setFeeds(
        RouteRead memory route,
        uint256[] memory w,
        uint256 first,
        uint256 n
    ) internal pure returns (bool ok) {
        route.legCount = SafeCast.toUint8(n);
        for (uint256 j = 0; j < n; ++j) {
            uint256 word = w[first + j];
            if (word > type(uint160).max) return false;
            route.legs[j].feed = address(SafeCast.toUint160(word));
        }
        return true;
    }

    /// @dev Reads the legs of a route and classifies it (`REQ-ORACLE-004`, `SPEC-ORC-002`, `SPEC-ORC-013`): valid only
    /// if every leg is valid and `1 <= r <= MAX_ROUTE_ANSWER`; `Stale` if every failing leg is `Stale` and `r` passes.
    /// @custom:spec REQ-ORACLE-004, SPEC-ORC-002, SPEC-ORC-013, REQ-ORACLE-092
    function _readRoute(
        RouteRead memory route
    ) internal view {
        bool oneLeg = route.legCount == 1;
        bool decoded = true;
        bool invalid = false;
        bool stale = false;
        route.updatedAt = type(uint64).max;
        route.staleFrom = type(uint64).max;
        for (uint256 j = 0; j < route.legCount; ++j) {
            LegRead memory leg = route.legs[j];
            _readLeg(leg, oneLeg);
            if (leg.status == ReadStatus.Error) {
                decoded = false;
                continue;
            }
            if (leg.status == ReadStatus.Invalid) invalid = true;
            if (leg.updatedAt < route.updatedAt) route.updatedAt = leg.updatedAt;
            if (leg.status == ReadStatus.Stale) {
                stale = true;
                // A Stale leg has updatedAt <= now < 2^64 and maxAge < 2^33, so the sum fits 64 bits.
                uint64 from = leg.updatedAt + leg.maxAge + 1;
                if (from < route.staleFrom) route.staleFrom = from;
            }
        }
        if (!decoded) {
            route.status = ReadStatus.Invalid;
            route.updatedAt = 0;
            return;
        }
        LegRead memory a = route.legs[0];
        LegRead memory b = route.legs[1];
        route.value = oneLeg
            ? LPPriceMath.routeValue(a.answer, a.pinnedDecimals)
            : LPPriceMath.routeValue(a.answer, a.pinnedDecimals, b.answer, b.pinnedDecimals);
        if (invalid || route.value == 0 || route.value > LPPriceMath.MAX_ROUTE_ANSWER) {
            route.status = ReadStatus.Invalid;
        } else if (stale) {
            route.status = ReadStatus.Stale;
        } else {
            route.status = ReadStatus.Valid;
        }
    }

    /// @dev Quote and failover (`REQ-ORACLE-005`), agreement (`SPEC-ORC-003`), failed state and failure start
    /// (`SPEC-ORC-013`), and the disagreement windows (`SPEC-ORC-016`, `REQ-ORACLE-095`).
    /// @custom:spec REQ-ORACLE-005, REQ-ORACLE-006, REQ-ORACLE-008, REQ-ORACLE-017, SPEC-ORC-003, SPEC-ORC-013, SPEC-ORC-016, REQ-ORACLE-022, REQ-ORACLE-095
    function _classify(
        DebtOracleLayout storage $,
        DebtEvaluation memory e,
        bool configOk
    ) internal view {
        if (!configOk) {
            e.failed = true;
            e.reasons |= R_CONFIG_UNAVAILABLE;
        } else {
            _selectQuote(e);
        }
        bool versionChanged = !e.routeVersionRead || e.routeVersion != $.routeVersion;
        e.disagreeSince = versionChanged ? 0 : $.disagreeSince;
        if (e.failed) {
            uint256 start = block.timestamp;
            if (e.sourceTimestampFailure) start = Math.min(start, e.staleAt);
            uint64 failedSince = $.failedSince;
            if (failedSince != 0) start = Math.min(start, failedSince);
            e.failureStart = SafeCast.toUint64(start);
            e.state = block.timestamp < start + e.cachedWindow ? PriceState.Cached : PriceState.Expired;
            return;
        }
        if (!e.disagree) {
            e.state = PriceState.Live;
            return;
        }
        e.state = PriceState.Drifting;
        uint256 s = e.disagreeSince != 0 ? e.disagreeSince : block.timestamp;
        e.pauseActive = block.timestamp < s + e.disagreementPauseMax;
        e.disagreementExpired = !e.pauseActive;
        e.reasons |= e.pauseActive ? R_DISAGREEMENT_PAUSE : R_DISAGREEMENT_EXPIRED;
    }

    /// @dev Primary when valid, else the alternate when valid, else no route (`REQ-ORACLE-005`); both valid and
    /// outside the tolerance disagree, and the quote stays the primary (`REQ-ORACLE-008`).
    /// @custom:spec REQ-ORACLE-005, REQ-ORACLE-008, REQ-ORACLE-019, SPEC-ORC-003, SPEC-ORC-013
    function _selectQuote(
        DebtEvaluation memory e
    ) internal pure {
        RouteRead memory p = e.routes[0];
        RouteRead memory b = e.routes[1];
        if (e.replaced != RouteSlot.None) e.reasons |= R_ON_STANDBY;
        bool pValid = p.status == ReadStatus.Valid;
        bool bValid = b.status == ReadStatus.Valid;
        if (pValid) {
            (e.routeUsed, e.quote, e.quoteUpdatedAt) = (RouteSlot.Primary, p.value, p.updatedAt);
        } else if (bValid) {
            (e.routeUsed, e.quote, e.quoteUpdatedAt) = (RouteSlot.Alternate, b.value, b.updatedAt);
            e.reasons |= R_ON_ALTERNATE;
        } else {
            e.failed = true;
            e.reasons |= R_NO_ROUTE;
            if (p.status == ReadStatus.Stale && b.status == ReadStatus.Stale) {
                e.sourceTimestampFailure = true;
                e.staleAt = p.staleFrom > b.staleFrom ? p.staleFrom : b.staleFrom;
                e.reasons |= R_SOURCE_TIMESTAMP_FAILURE;
            }
        }
        if (pValid && bValid && !LPPriceMath.routesAgree(p.value, b.value, e.toleranceBps)) {
            e.disagree = true;
            e.reasons |= R_DISAGREE;
        }
    }

    /// @dev Served price (`SPEC-ORC-018`), the route it comes from, its source timestamp and its age limits
    /// (`SPEC-ORC-012`, `SPEC-ORC-015`), and the alternate held to its borrow age (`REQ-ORACLE-090`). While the routes
    /// disagree the served value is the larger of `A` and the routes that count (`_countedRoutes`): the higher route
    /// only when the second source confirms it, else the lower one, so one faulty route cannot raise the debt price
    /// alone (ORACLE-06); its route is the counted route, and when `A` exceeds it, no route: the accepted timestamp is
    /// reported with age limits 0, as when failed.
    /// @custom:spec SPEC-ORC-018, SPEC-ORC-012, SPEC-ORC-015, REQ-ORACLE-090, REQ-ORACLE-093, REQ-ORACLE-021, REQ-ORACLE-066
    function _serve(
        DebtEvaluation memory e
    ) internal view {
        (uint256 p, uint256 b) = _countedRoutes(e);
        e.served = LPPriceMath.debtServedPrice(e.state, e.quote, p, b, e.accepted, e.stressRiseBps);
        e.servedRoute = _servedRoute(e);
        if (e.servedRoute == RouteSlot.None) {
            e.servedUpdatedAt = e.acceptedUpdatedAt;
            return;
        }
        bool onAlternate = e.servedRoute == RouteSlot.Alternate;
        RouteRead memory route = e.routes[onAlternate ? 1 : 0];
        e.servedUpdatedAt = route.updatedAt;
        LPPriceMath.LegAge[] memory legs = new LPPriceMath.LegAge[](route.legCount);
        for (uint256 j = 0; j < route.legCount; ++j) {
            LegRead memory leg = route.legs[j];
            legs[j] = LPPriceMath.LegAge({
                updatedAt: leg.updatedAt,
                borrowPriceMaxAge: leg.borrowMaxAge,
                liquidationPriceMaxAge: leg.liquidationMaxAge,
                onAlternate: onAlternate
            });
            if (onAlternate && block.timestamp - leg.updatedAt > leg.borrowMaxAge) e.alternatePastBorrowAge = true;
        }
        (e.borrowPriceMaxAge, e.liquidationPriceMaxAge) = LPPriceMath.ageLimits(legs, false);
        if (e.alternatePastBorrowAge) e.reasons |= R_ALTERNATE_PAST_BORROW_AGE;
    }

    /// @dev The route values `debtServedPrice` takes while Drifting. The routes disagree, so one of them is wrong and
    /// the oracle cannot tell which from the two alone: the higher route counts only when the second source confirms
    /// it (`SPEC-ORC-020` test against that route); otherwise both inputs are the lower route, and the served value is
    /// `max(min(p, b), A)`, the median of `p`, `b` and `A`. A rise of the debt asset seen by one route and the second
    /// source is served; a rise seen by one route alone is not, and the debt still never counts below `A`. Outside
    /// Drifting the routes are passed unchanged (`debtServedPrice` does not use them).
    /// @custom:spec SPEC-ORC-018, SPEC-ORC-020
    function _countedRoutes(
        DebtEvaluation memory e
    ) internal pure returns (uint256 p, uint256 b) {
        (p, b) = (e.routes[0].value, e.routes[1].value);
        if (e.state != PriceState.Drifting) return (p, b);
        uint256 high = Math.max(p, b);
        if (LPPriceMath.secondSourceAgrees(e.secondValid, high, e.secondValue, e.secondToleranceBps)) return (p, b);
        uint256 low = Math.min(p, b);
        return (low, low);
    }

    /// @dev The route the served value comes from: none when failed; while Drifting the route of the larger counted
    /// value (`_countedRoutes`; a tie of the routes is impossible, they disagree), or none when `A` exceeds it;
    /// otherwise the quote's route.
    /// @custom:spec SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-018
    function _servedRoute(
        DebtEvaluation memory e
    ) internal pure returns (RouteSlot slot) {
        if (e.failed) return RouteSlot.None;
        if (e.state != PriceState.Drifting) return e.routeUsed;
        (uint256 cp, uint256 cb) = _countedRoutes(e);
        uint256 counted = Math.max(cp, cb);
        if (e.accepted > counted) return RouteSlot.None;
        return e.routes[1].value == counted ? RouteSlot.Alternate : RouteSlot.Primary;
    }

    /// @dev Sequencer gate (`SPEC-ORC-021`, `REQ-ORACLE-099`); a failed `sequencer()` read, or an uptime answer that is
    /// not exactly 160 bytes, is `sequencerUnknown`.
    /// @custom:spec SPEC-ORC-021, REQ-ORACLE-099, REQ-ORACLE-092
    function _readSequencer(
        address store,
        DebtEvaluation memory e
    ) internal view {
        (bool s,, uint256[] memory w) =
            _call(store, CONFIG_CALL_GAS, abi.encodeCall(IParameterStoreChain.sequencer, ()), 2);
        bool up = false;
        bool down = false;
        bool unknown = false;
        bool inGrace = false;
        bool ready = false;
        if (!s || w.length < 2 || w[0] > type(uint160).max || w[1] > type(uint32).max) {
            unknown = true;
        } else {
            address feed = address(SafeCast.toUint160(w[0]));
            bool readOk = false;
            int256 answer = 0;
            uint256 startedAt = 0;
            uint256 size = 0;
            if (feed != address(0)) (readOk,, answer, startedAt,, size) = _readLatest(feed);
            (up, down, unknown, inGrace, ready) = LPPriceMath.sequencerStatus(
                feed != address(0), readOk && size == 160, answer, startedAt, block.timestamp, w[1]
            );
            // In grace, startedAt <= now < 2^64 and the period fits 32 bits.
            if (inGrace) e.sequencerGraceEndsAt = SafeCast.toUint64(startedAt + w[1]);
            // A borrow also needs the served round newer than the restart (`_serve` ran first): a price from rounds
            // before it is not ready for borrowing. `sequencerReady` gates only `borrowAllowed`.
            if (up && e.servedUpdatedAt <= startedAt) ready = false;
        }
        // Ready implies up (SPEC-ORC-021); a chain without a feed is ready and reports up as false.
        (e.sequencerDown, e.sequencerUnknown, e.sequencerGrace, e.sequencerReady) = (down, unknown, inGrace, ready);
        if (down || unknown) e.reasons |= R_SEQUENCER_DOWN;
        if (inGrace) e.reasons |= R_SEQUENCER_GRACE;
    }

    /// @dev Grace window (`REQ-ORACLE-034`, `REQ-ORACLE-099`): the stored recovery window or the sequencer restart.
    /// @custom:spec REQ-ORACLE-034, REQ-ORACLE-099
    function _grace(
        DebtEvaluation memory e
    ) internal view {
        uint64 rec = e.recoveredAt;
        if (rec != 0) e.graceEndsAt = rec + e.graceDuration;
        bool priceGrace = rec != 0 && rec <= block.timestamp && block.timestamp < e.graceEndsAt;
        if (e.sequencerGrace && e.sequencerGraceEndsAt > e.graceEndsAt) e.graceEndsAt = e.sequencerGraceEndsAt;
        e.inGrace = priceGrace || e.sequencerGrace;
        if (e.inGrace) e.reasons |= R_IN_GRACE;
    }

    /// @dev Second-source confirmation (`SPEC-ORC-020`): an `OracleNetwork` aggregator held to the leg rules with its
    /// feed record's pinned decimals and bounds and `maxAge`; any other source or failed read is unconfirmed.
    /// @custom:spec SPEC-ORC-020, REQ-ORACLE-100, REQ-ORACLE-092
    function _readSecondSource(
        DebtOracleLayout storage $,
        DebtEvaluation memory e
    ) internal view {
        address store = $.parameterStore;
        (bool s,, uint256[] memory w) = _callOf(store, IParameterStoreViews.secondSource.selector, $.asset, 6);
        bool usable = s && w.length == 6 && w[0] == uint256(SecondSourceKind.OracleNetwork) && w[1] <= type(uint160).max
            && w[3] <= type(uint32).max && w[5] <= type(uint16).max;
        if (usable) {
            LegRead memory src = _newLeg(address(SafeCast.toUint160(w[1])));
            if (_readFeedDef(store, src)) {
                src.maxAge = SafeCast.toUint64(w[3]);
                _readLeg(src, true);
                e.secondValue = LPPriceMath.normalizeAnswer(src.answer, src.pinnedDecimals);
                e.secondValid = src.status == ReadStatus.Valid;
                e.secondToleranceBps = SafeCast.toUint16(w[5]);
                e.confirmed =
                    LPPriceMath.secondSourceAgrees(e.secondValid, e.quote, e.secondValue, e.secondToleranceBps);
            }
        }
        if (!e.confirmed) e.reasons |= R_SECOND_SOURCE_DISAGREE;
    }

    /// @dev A leg record naming only its feed.
    function _newLeg(
        address feed
    ) internal pure returns (LegRead memory leg) {
        leg.feed = feed;
    }
}
