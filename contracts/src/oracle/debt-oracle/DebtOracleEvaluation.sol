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
/// @notice One evaluation of the debt asset, shared by every view and `poke()`.
/// @dev Writes nothing and never reverts except `InsufficientGas`.
abstract contract DebtOracleEvaluation is DebtOracleReads {
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
        _serve(e);
        _readSequencer($.parameterStore, e);
        _grace(e);
        if (!e.failed) _readSecondSource($, e);
        e.liquidationPaused = e.state != PriceState.Live || e.alternatePastBorrowAge || e.sequencerDown;
        e.borrowAllowed = e.state == PriceState.Live && e.sequencerReady && e.confirmed
            && block.timestamp - e.servedUpdatedAt <= e.borrowPriceMaxAge;
    }

    /// @dev Every configuration read; false when one fails. Failed window or stress-rise reads use stored values.
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

    function _readListed(
        address registry,
        address asset
    ) internal view returns (bool listed) {
        (bool s,, uint256[] memory w) = _callOf(registry, IMarketRegistryViews.getToken.selector, asset, 2);
        return s && w.length == 2 && w[0] == 32 && w[1] == 1;
    }

    /// @dev `MarketRegistry.activePriceRoutes(asset)`: two routes of one or two legs; any other shape fails.
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

    function _readRoute(
        RouteRead memory route
    ) internal view {
        bool oneLeg = route.legCount == 1;
        bool decoded = true;
        bool anyInvalid = false;
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
            if (leg.status == ReadStatus.Invalid) anyInvalid = true;
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
        if (anyInvalid || route.value == 0 || route.value > LPPriceMath.MAX_ROUTE_ANSWER) {
            route.status = ReadStatus.Invalid;
        } else if (stale) {
            route.status = ReadStatus.Stale;
        } else {
            route.status = ReadStatus.Valid;
        }
    }

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

    /// @dev Primary when valid, else the alternate, else no route; the quote stays the primary on disagreement.
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

    /// @dev While Drifting serves `max(min(p, b), A)`, so one faulty route cannot raise the debt price alone.
    function _serve(
        DebtEvaluation memory e
    ) internal view {
        uint256 low = Math.min(e.routes[0].value, e.routes[1].value);
        e.served = LPPriceMath.debtServedPrice(e.state, e.quote, low, low, e.accepted, e.stressRiseBps);
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

    /// @dev The route the served value comes from; none when failed or the accepted price is served.
    function _servedRoute(
        DebtEvaluation memory e
    ) internal pure returns (RouteSlot slot) {
        if (e.failed) return RouteSlot.None;
        if (e.state != PriceState.Drifting) return e.routeUsed;
        uint256 p = e.routes[0].value;
        uint256 b = e.routes[1].value;
        if (e.accepted > Math.min(p, b)) return RouteSlot.None;
        return b < p ? RouteSlot.Alternate : RouteSlot.Primary;
    }

    /// @dev Sequencer gate; a failed or malformed read is `sequencerUnknown`.
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
            if (inGrace) e.sequencerGraceEndsAt = SafeCast.toUint64(startedAt + w[1]);
            // Borrowing also needs the served round newer than the restart (`_serve` ran first).
            if (up && e.servedUpdatedAt <= startedAt) ready = false;
        }
        (e.sequencerDown, e.sequencerUnknown, e.sequencerGrace, e.sequencerReady) = (down, unknown, inGrace, ready);
        if (down || unknown) e.reasons |= R_SEQUENCER_DOWN;
        if (inGrace) e.reasons |= R_SEQUENCER_GRACE;
    }

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

    /// @dev Only an `OracleNetwork` aggregator held to the leg rules can confirm.
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
                uint256 value = LPPriceMath.normalizeAnswer(src.answer, src.pinnedDecimals);
                e.confirmed = LPPriceMath.secondSourceAgrees(
                    src.status == ReadStatus.Valid, e.quote, value, SafeCast.toUint16(w[5])
                );
            }
        }
        if (!e.confirmed) e.reasons |= R_SECOND_SOURCE_DISAGREE;
    }

    function _newLeg(
        address feed
    ) internal pure returns (LegRead memory leg) {
        leg.feed = feed;
    }
}
