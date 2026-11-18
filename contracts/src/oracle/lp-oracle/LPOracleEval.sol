// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {PriceState} from "../../types/PriceState.sol";
import {LPOracleConfig} from "./LPOracleConfig.sol";
import {Evaluation, LPOracleCodes, LegEval, RouteEval, TokenEval} from "./LPOracleTypes.sol";
import {LPPriceMath} from "./LPPriceMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LPOracleEval
/// @notice The valuation pipeline every view and `poke()` runs, from quotes to state, served price and gates.
/// @dev Writes no storage. A failed read never reverts; it moves the market to a stricter state.
abstract contract LPOracleEval is LPOracleConfig {
    /// @dev Evaluation with the live configuration; second sources never change the served price or state.
    function _evaluate(
        bool secondSources
    ) internal view returns (Evaluation memory e) {
        _allocate(e);
        _loadLive(e, secondSources);
        _storedDecimals(e);
        _complete(e, secondSources);
    }

    /// @dev The evaluation of `poke()`: reads the token decimals instead of using the stored result.
    function _evaluatePoke() internal view returns (Evaluation memory e) {
        _allocate(e);
        _loadLive(e, true);
        _verifyDecimals(e);
        _complete(e, true);
    }

    /// @dev Applies the stored token-decimals result; fails the market while it is invalid.
    function _storedDecimals(
        Evaluation memory e
    ) internal view {
        Layout storage $ = _s();
        e.decimalsCheckedAt = $.decimalsCheckedAt;
        if (!$.decimalsInvalid) return;
        _failRead(e);
    }

    /// @dev Evaluation with `config` as configuration (`initialize`); skips second sources.
    function _evaluateSeed(
        OracleConfig calldata config
    ) internal view returns (Evaluation memory e) {
        _allocate(e);
        _loadSeed(e, config);
        _complete(e, false);
    }

    function _allocate(
        Evaluation memory e
    ) internal view {
        uint256 n = _s().tokens.length;
        e.tokens = new TokenEval[](n);
        e.quotes = new uint256[](n);
        e.prices = new uint256[](n);
    }

    function _complete(
        Evaluation memory e,
        bool secondSources
    ) internal view {
        if (!e.failed) _selectQuotes(e);
        if (!e.failed) _valueMarket(e);
        if (!e.failed && secondSources) _secondSources(e);
        _decide(e);
    }

    /// @dev Quote per token with failover, route agreement, valuation price and the token reason bits.
    function _selectQuotes(
        Evaluation memory e
    ) internal view {
        Layout storage $ = _s();
        uint256 n = e.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            TokenEval memory t = e.tokens[i];
            RouteEval memory p = t.routes[0];
            RouteEval memory b = t.routes[1];
            if (p.status == LPOracleCodes.VALID) {
                (t.used, t.quote, t.updatedAt) = (LPOracleCodes.ROUTE_PRIMARY, p.value, p.updatedAt);
                if (b.status == LPOracleCodes.VALID && !LPPriceMath.routesAgree(p.value, b.value, t.tolerance)) {
                    t.disagree = true;
                    t.reasons |= LPOracleCodes.TOKEN_DISAGREE;
                }
            } else if (b.status == LPOracleCodes.VALID) {
                (t.used, t.quote, t.updatedAt) = (LPOracleCodes.ROUTE_ALTERNATE, b.value, b.updatedAt);
                t.reasons |= LPOracleCodes.TOKEN_ON_ALTERNATE;
                e.reasons |= LPOracleCodes.ANY_TOKEN_ON_ALTERNATE;
            } else {
                _noRoute(e, t);
            }
            if (t.replaced != 0) {
                t.reasons |= LPOracleCodes.TOKEN_ON_STANDBY;
                e.reasons |= LPOracleCodes.ANY_TOKEN_ON_STANDBY;
            }
            e.quotes[i] = t.quote;
            t.price = LPPriceMath.valuationPrice(t.quote, $.isUsdStable[i]);
            e.prices[i] = t.price;
        }
    }

    /// @dev A token with no valid route fails the market; if both routes are stale, records the stale start.
    function _noRoute(
        Evaluation memory e,
        TokenEval memory t
    ) private pure {
        t.reasons |= LPOracleCodes.TOKEN_NO_ROUTE;
        e.reasons |= LPOracleCodes.ANY_TOKEN_NO_ROUTE;
        e.failed = true;
        RouteEval memory p = t.routes[0];
        RouteEval memory b = t.routes[1];
        if (p.status != LPOracleCodes.STALE || b.status != LPOracleCodes.STALE) return;
        t.bothStale = true;
        t.staleAt = p.staleFrom > b.staleFrom ? p.staleFrom : b.staleFrom;
        if (!e.hasStaleStart || t.staleAt < e.staleStart) e.staleStart = t.staleAt;
        e.hasStaleStart = true;
        e.reasons |= LPOracleCodes.SOURCE_TIMESTAMP_FAILURE;
    }

    function _valueMarket(
        Evaluation memory e
    ) internal view {
        PoolCheck memory poolCheck = _poolCheck(e.quotes, e.prices, e.cfg.twapWindow, e.cfg.consistencyToleranceBps);
        if (!poolCheck.readOk) {
            _failRead(e);
            return;
        }
        if (poolCheck.locked) {
            e.reasons |= LPOracleCodes.POOL_REENTRANCY_LOCKED;
            e.failed = true;
            return;
        }
        bool ok = false;
        (ok, e.fresh) = _price(e.prices);
        if (!ok) {
            _failRead(e);
            return;
        }
        (bool bandValid, bool inBand) = LPPriceMath.inUsdBand(e.quotes, e.prices, e.cfg.usdBandLow, e.cfg.usdBandHigh);
        if (!bandValid) {
            _failRead(e);
            return;
        }
        if (!inBand) e.reasons |= LPOracleCodes.USD_BAND;
        _consistencyBits(e, poolCheck);
        _chooseRoutes(e);
        if (e.disagreeing) {
            uint256[] memory w = new uint256[](e.tokens.length);
            for (uint256 i = 0; i < w.length; ++i) {
                w[i] = e.tokens[i].lowerPrice;
            }
            (ok, e.lower) = _price(w);
            if (!ok) {
                _failRead(e);
                return;
            }
        }
    }

    function _price(
        uint256[] memory prices
    ) internal view returns (bool ok, uint256 price8) {
        Layout storage $ = _s();
        uint256[] memory amounts;
        (ok, amounts) = _composition(10 ** uint256($.vaultDecimals), prices);
        if (!ok) return (false, 0);
        (ok, price8) = LPPriceMath.lpPrice(amounts, prices, $.tokenDecimals);
    }

    function _consistencyBits(
        Evaluation memory e,
        PoolCheck memory poolCheck
    ) private pure {
        e.consistencyDeviationBps = poolCheck.available ? poolCheck.deviationBps : type(uint256).max;
        if (!poolCheck.available) e.reasons |= LPOracleCodes.CONSISTENCY_UNAVAILABLE;
        else if (!poolCheck.pass) e.reasons |= LPOracleCodes.CONSISTENCY_DEVIATION;
        if (poolCheck.clamped) e.reasons |= LPOracleCodes.PRICE_CLAMPED;
    }

    /// @dev The route serving each token: during a disagreement the lower valid route (primary on a tie).
    function _chooseRoutes(
        Evaluation memory e
    ) private view {
        Layout storage $ = _s();
        uint256 n = e.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            if (e.tokens[i].disagree) e.disagreeing = true;
        }
        if (e.disagreeing) e.reasons |= LPOracleCodes.ANY_TOKEN_DISAGREE;
        for (uint256 i = 0; i < n; ++i) {
            TokenEval memory t = e.tokens[i];
            (t.chosen, t.chosenAt, t.lowerPrice) = (t.used, t.updatedAt, t.price);
            RouteEval memory p = t.routes[0];
            RouteEval memory b = t.routes[1];
            if (!e.disagreeing || p.status != LPOracleCodes.VALID || b.status != LPOracleCodes.VALID) continue;
            uint256 lowest = b.value < p.value ? b.value : p.value;
            t.lowerPrice = LPPriceMath.valuationPrice(lowest, $.isUsdStable[i]);
            if (b.value < p.value) (t.chosen, t.chosenAt) = (LPOracleCodes.ROUTE_ALTERNATE, b.updatedAt);
        }
    }

    function _secondSources(
        Evaluation memory e
    ) internal view {
        uint256 n = e.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            TokenEval memory t = e.tokens[i];
            _readSecondSource(t, i, e.quotes);
            t.confirmed = LPPriceMath.secondSourceAgrees(t.secondValid, t.quote, t.secondValue, t.second.toleranceBps);
            if (t.confirmed) continue;
            t.reasons |= t.secondValid
                ? LPOracleCodes.TOKEN_SECOND_SOURCE_DISAGREE
                : LPOracleCodes.TOKEN_SECOND_SOURCE_UNAVAILABLE;
            e.reasons |= LPOracleCodes.SECOND_SOURCE_DISAGREE;
        }
    }

    function _decide(
        Evaluation memory e
    ) internal view {
        Layout storage $ = _s();
        if (e.failed) _decideFailed(e);
        else _decideLive(e);
        e.served = LPPriceMath.servedPrice(
            e.state, e.disagreeing && !e.failed, e.fresh, e.lower, SafeCast.toUint256($.accepted.answer)
        );
        if (e.seq.down || e.seq.unknown) e.reasons |= LPOracleCodes.SEQUENCER_DOWN;
        if (e.seq.inGrace) e.reasons |= LPOracleCodes.SEQUENCER_GRACE;
        _grace(e);
        e.liquidationPaused = e.state == PriceState.Cached || e.state == PriceState.Expired || e.pauseActive
            || e.disagreementExpired || e.alternatePastBorrowAge || e.seq.down;
        if (block.timestamp - e.decimalsCheckedAt > DECIMALS_CHECK_MAX_AGE) {
            e.reasons |= LPOracleCodes.DECIMALS_UNVERIFIED;
        }
        // On an L2 the served price must come from rounds newer than the sequencer's restart.
        e.borrowAllowed = e.state == PriceState.Live && e.seq.ready
            && (e.reasons & (LPOracleCodes.SECOND_SOURCE_DISAGREE | LPOracleCodes.DECIMALS_UNVERIFIED)) == 0
            && block.timestamp - e.servedUpdatedAt <= e.borrowMaxAge && e.servedUpdatedAt > e.seq.startedAt;
    }

    /// @dev A failed market: Cached until `failureStart + cachedWindow`, then Expired.
    function _decideFailed(
        Evaluation memory e
    ) private view {
        Layout storage $ = _s();
        e.reasons &= ~LPOracleCodes.NOT_EVALUATED_WHEN_FAILED;
        uint64 start = _now64();
        if (e.hasStaleStart && e.staleStart < start) start = e.staleStart;
        uint64 since = $.failedSince;
        if (since != 0 && since < start) start = since;
        uint64 window = e.cfg.ok ? e.cfg.cachedWindow : $.lastCachedWindow;
        e.failureStart = start;
        e.cachedUntil = start + window;
        e.state = block.timestamp < e.cachedUntil ? PriceState.Cached : PriceState.Expired;
        e.servedUpdatedAt = $.accepted.updatedAt;
    }

    /// @dev A market that is not failed: Drifting or Live, quote-change cap, disagreement windows and age limits.
    function _decideLive(
        Evaluation memory e
    ) private view {
        Layout storage $ = _s();
        e.state = (e.reasons & LPOracleCodes.DRIFTING_BITS) != 0 ? PriceState.Drifting : PriceState.Live;
        e.disagreeSince = e.versionChanged ? 0 : $.disagreeSince;
        if (e.disagreeing) {
            uint256 s = e.disagreeSince != 0 ? e.disagreeSince : block.timestamp;
            e.pauseActive = block.timestamp < s + e.cfg.disagreementPauseMax;
            e.disagreementExpired = !e.pauseActive;
            e.reasons |= e.pauseActive ? LPOracleCodes.DISAGREEMENT_PAUSE : LPOracleCodes.DISAGREEMENT_EXPIRED;
        }
        if (e.state == PriceState.Live && _quoteCapped(e.fresh, e.cfg.maxQuoteChangeBps)) {
            e.state = PriceState.Cached;
            e.quoteCapped = true;
            e.reasons |= LPOracleCodes.QUOTE_CHANGE_CAPPED;
            e.servedUpdatedAt = $.accepted.updatedAt;
            return;
        }
        _ages(e);
    }

    /// @dev The accepted price was stored in this block and the fair price differs from it by more than the cap.
    function _quoteCapped(
        uint256 fresh,
        uint16 maxQuoteChangeBps
    ) internal view returns (bool) {
        Layout storage $ = _s();
        if ($.acceptedBlock != block.number) return false;
        uint256 accepted = SafeCast.toUint256($.accepted.answer);
        uint256 diff = fresh > accepted ? fresh - accepted : accepted - fresh;
        return diff * LPPriceMath.BPS > uint256(maxQuoteChangeBps) * accepted;
    }

    function _ages(
        Evaluation memory e
    ) private view {
        uint256 n = e.tokens.length;
        uint256 count = 0;
        for (uint256 i = 0; i < n; ++i) {
            count += e.tokens[i].routes[e.tokens[i].chosen - 1].legCount;
        }
        LPPriceMath.LegAge[] memory legs = new LPPriceMath.LegAge[](count);
        uint64[] memory times = new uint64[](n);
        count = 0;
        for (uint256 i = 0; i < n; ++i) {
            TokenEval memory t = e.tokens[i];
            bool alternate = t.chosen == LPOracleCodes.ROUTE_ALTERNATE;
            RouteEval memory route = t.routes[t.chosen - 1];
            times[i] = t.chosenAt;
            for (uint256 l = 0; l < route.legCount; ++l) {
                LegEval memory leg = route.legs[l];
                legs[count++] = LPPriceMath.LegAge({
                    updatedAt: leg.updatedAt,
                    borrowPriceMaxAge: leg.borrowAge,
                    liquidationPriceMaxAge: leg.liquidationAge,
                    onAlternate: alternate
                });
                if (alternate && block.timestamp - leg.updatedAt > leg.borrowAge) e.alternatePastBorrowAge = true;
            }
        }
        e.servedUpdatedAt = LPPriceMath.servedTimestamp(times, false, 0);
        (e.borrowMaxAge, e.liquidationMaxAge) = LPPriceMath.ageLimits(legs, false);
        if (e.alternatePastBorrowAge) e.reasons |= LPOracleCodes.ALTERNATE_PAST_BORROW_AGE;
    }

    function _grace(
        Evaluation memory e
    ) private view {
        uint64 recovered = _s().recoveredAt;
        uint256 end = recovered != 0 ? uint256(recovered) + e.cfg.graceDuration : 0;
        bool recovering = recovered != 0 && recovered <= block.timestamp && block.timestamp < end;
        if (e.seq.inGrace) {
            uint256 seqEnd = uint256(e.seq.startedAt) + e.cfg.sequencerGracePeriod;
            if (seqEnd > end) end = seqEnd;
        }
        e.inGrace = recovering || e.seq.inGrace;
        e.graceEndsAt = SafeCast.toUint64(end);
        if (e.inGrace) e.reasons |= LPOracleCodes.IN_GRACE;
    }
}
