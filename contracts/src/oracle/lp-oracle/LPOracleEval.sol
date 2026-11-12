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
/// @notice The valuation pipeline every view and `poke()` runs in the same order (2.10 Valuation pipeline): quote per
/// token with failover and agreement, the stable ceiling, the fresh price from the pricing module's composition, the
/// USD band, the consistency check, the lower-route price of a disagreement, the second sources, then the state,
/// timers, served price, age limits and gates.
/// @dev Pure of storage writes. A failed read never reverts: it moves the market to a stricter state. The state is
/// computed on every read from current data plus the stored timers (`REQ-ORACLE-016`): failed → Cached until
/// `failureStart + cachedWindow`, then Expired (`SPEC-ORC-013`); not failed → Drifting on any of reason bits 2 to 6,
/// else Live, and Cached for the block when the quote-change cap refuses the fair price (`REQ-ORACLE-103`).
/// @custom:spec REQ-ORACLE-005, REQ-ORACLE-006, REQ-ORACLE-008, REQ-ORACLE-009, REQ-ORACLE-011, REQ-ORACLE-015, REQ-ORACLE-016, REQ-ORACLE-017, REQ-ORACLE-018, REQ-ORACLE-019, REQ-ORACLE-020, REQ-ORACLE-022, REQ-ORACLE-034, REQ-ORACLE-090, REQ-ORACLE-095, REQ-ORACLE-099, REQ-ORACLE-100, REQ-ORACLE-103, SPEC-ORC-012, SPEC-ORC-013, SPEC-ORC-015, SPEC-ORC-016, SPEC-ORC-017
abstract contract LPOracleEval is LPOracleConfig {
    /// @dev Evaluation of the market with the live configuration and routes in force. `secondSources` false skips the
    /// second sources, which change only reason bit 16, the token bits 4 and 5 and `borrowAllowed` (`REQ-ORACLE-100`):
    /// the served-price views (`latestAnswer`, `latestRoundData`, `getTokenPrices` and the two age views) return
    /// nothing those fields reach, so they skip them; `getPriceState` and `poke()` evaluate them.
    /// @custom:spec REQ-ORACLE-026, REQ-ORACLE-042, REQ-ORACLE-045, REQ-ORACLE-100
    function _evaluate(
        bool secondSources
    ) internal view returns (Evaluation memory e) {
        _allocate(e);
        _loadLive(e, secondSources);
        _storedDecimals(e);
        _complete(e, secondSources);
    }

    /// @dev The evaluation of `poke()`: the evaluation of `getPriceState()` with the token decimals verified by reading
    /// them (`_verifyDecimals`) in place of the stored result of the last `poke()` (`REQ-ORACLE-107`).
    /// @custom:spec REQ-ORACLE-026, REQ-ORACLE-107
    function _evaluatePoke() internal view returns (Evaluation memory e) {
        _allocate(e);
        _loadLive(e, true);
        _verifyDecimals(e);
        _complete(e, true);
    }

    /// @dev The token-decimals result of the last `poke()` (`REQ-ORACLE-107`): its verification time, and reason bit 1
    /// with a failed market while it found a token's decimals changed or unreadable.
    /// @custom:spec REQ-ORACLE-107
    function _storedDecimals(
        Evaluation memory e
    ) internal view {
        Layout storage $ = _s();
        e.decimalsCheckedAt = $.decimalsCheckedAt;
        if (!$.decimalsInvalid) return;
        _failRead(e);
    }

    /// @dev Evaluation of the market with `config` as configuration and routes (`initialize`). Second sources are not
    /// read: they never change the state (`REQ-ORACLE-100`), the seed needs only a Live state, and `checkConfig` checks
    /// them.
    /// @custom:spec REQ-ORACLE-058, REQ-ORACLE-059
    function _evaluateSeed(
        OracleConfig calldata config
    ) internal view returns (Evaluation memory e) {
        _allocate(e);
        _loadSeed(e, config);
        _complete(e, false);
    }

    /// @dev Allocates the per-token arrays.
    function _allocate(
        Evaluation memory e
    ) internal view {
        uint256 n = _s().tokens.length;
        e.tokens = new TokenEval[](n);
        e.quotes = new uint256[](n);
        e.prices = new uint256[](n);
    }

    /// @dev The pipeline after the inputs are loaded; `secondSources` false skips the second sources (the seed and the
    /// served-price views).
    function _complete(
        Evaluation memory e,
        bool secondSources
    ) internal view {
        if (!e.failed) _selectQuotes(e);
        if (!e.failed) _valueMarket(e);
        if (!e.failed && secondSources) _secondSources(e);
        _decide(e);
    }

    // ─── Quotes ───

    /// @dev Quote per token (`REQ-ORACLE-005`), agreement (`REQ-ORACLE-008`, `SPEC-ORC-003`), valuation price
    /// (`SPEC-ORC-004`), the failure start from source timestamps (`SPEC-ORC-013`) and the token reason bits.
    /// @custom:spec REQ-ORACLE-005, REQ-ORACLE-006, REQ-ORACLE-008, REQ-ORACLE-009, REQ-ORACLE-019, SPEC-ORC-013
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

    /// @dev A token with no valid route fails the market; if both its routes are `Stale`, `staleAt_i` feeds `S_ts`.
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

    // ─── Value ───

    /// @dev Pool lock, fresh price, USD band and level, consistency, disagreement and the lower-route price.
    /// @custom:spec REQ-ORACLE-011, REQ-ORACLE-015, REQ-ORACLE-018, REQ-ORACLE-086, REQ-ORACLE-103, SPEC-ORC-011, SPEC-ORC-017
    function _valueMarket(
        Evaluation memory e
    ) internal view {
        (bool readOk, bool locked) = _poolLocked();
        if (!readOk) {
            _failRead(e);
            return;
        }
        if (locked) {
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
        _consistencyBits(e);
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

    /// @dev `price8` at `prices` from the pricing module's composition of one whole vault token (`SPEC-ORC-008`).
    /// @custom:spec SPEC-ORC-008, REQ-ORACLE-011, REQ-ORACLE-103
    function _price(
        uint256[] memory prices
    ) internal view returns (bool ok, uint256 price8) {
        Layout storage $ = _s();
        uint256[] memory amounts;
        (ok, amounts) = _composition(10 ** uint256($.vaultDecimals), prices);
        if (!ok) return (false, 0);
        (ok, price8) = LPPriceMath.lpPrice(amounts, prices, $.tokenDecimals);
    }

    /// @dev Reason bits 4, 5 and 6 from the pricing module's consistency check (`REQ-ORACLE-014`, `REQ-ORACLE-104`).
    function _consistencyBits(
        Evaluation memory e
    ) private view {
        (bool available, bool pass, uint256 deviation, bool clamped) =
            _consistency(e.quotes, e.prices, e.cfg.twapWindow, e.cfg.consistencyToleranceBps);
        e.consistencyDeviationBps = available ? deviation : type(uint256).max;
        if (!available) e.reasons |= LPOracleCodes.CONSISTENCY_UNAVAILABLE;
        else if (!pass) e.reasons |= LPOracleCodes.CONSISTENCY_DEVIATION;
        if (clamped) e.reasons |= LPOracleCodes.PRICE_CLAMPED;
    }

    /// @dev The route serving each token (`SPEC-ORC-017`): during a disagreement, the lower of two valid routes (the
    /// primary on a tie) with `w_i = ceil_i(min(p_i, b_i))`; otherwise the quote route with `w_i = v_i`.
    /// @custom:spec SPEC-ORC-017, REQ-ORACLE-086
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

    /// @dev Second-source confirmation of every token (`SPEC-ORC-020`); reason bit 16 when some token is not confirmed.
    /// @custom:spec SPEC-ORC-020, REQ-ORACLE-100
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

    // ─── State ───

    /// @dev State, failure start, disagreement windows, served price and timestamp, age limits, grace and gates.
    /// `borrowAllowed` also requires, on an L2, a served timestamp newer than the sequencer's restart (`SPEC-ORC-021`),
    /// every token confirmed (`REQ-ORACLE-100`) and the token decimals verified within
    /// `DECIMALS_CHECK_MAX_AGE` (reason bit 19, `REQ-ORACLE-107`); neither changes the state, the served price or a timer.
    /// @custom:spec REQ-ORACLE-016, REQ-ORACLE-017, REQ-ORACLE-018, REQ-ORACLE-020, REQ-ORACLE-022, REQ-ORACLE-034, REQ-ORACLE-084, REQ-ORACLE-090, REQ-ORACLE-095, REQ-ORACLE-099, REQ-ORACLE-100, REQ-ORACLE-103, REQ-ORACLE-107, SPEC-ORC-013, SPEC-ORC-016, SPEC-ORC-017, SPEC-ORC-021
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
        // On an L2 the served price must also come from rounds newer than the sequencer's restart (`SPEC-ORC-021`):
        // `servedUpdatedAt` is the oldest leg in use, and `seq.startedAt` is 0 without a feed or while not up.
        e.borrowAllowed = e.state == PriceState.Live && e.seq.ready
            && (e.reasons & (LPOracleCodes.SECOND_SOURCE_DISAGREE | LPOracleCodes.DECIMALS_UNVERIFIED)) == 0
            && block.timestamp - e.servedUpdatedAt <= e.borrowMaxAge && e.servedUpdatedAt > e.seq.startedAt;
    }

    /// @dev A failed market: `failureStart = min(S_ts, failedSince, now)`, Cached before `failureStart +
    /// cachedWindow`, Expired from then on (`SPEC-ORC-013`); served at the accepted timestamp with age limits 0.
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

    /// @dev A market that is not failed: Drifting or Live, the quote-change cap, the disagreement windows of
    /// `SPEC-ORC-016` measured from `disagreeSince` (0 after a route-version change, `REQ-ORACLE-095`), the served
    /// timestamp and the age limits of the routes in use.
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

    /// @dev The quote-change cap (`REQ-ORACLE-103`): the accepted price was stored in this block and the fair price
    /// differs from it by more than `maxQuoteChangeBps`: `|price8 - A| * 10^4 > maxQuoteChangeBps * A`.
    /// @custom:spec REQ-ORACLE-103, REQ-AMM-CORE-014
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

    /// @dev Served timestamp and age limits over the legs of each token's route in use (`SPEC-ORC-012`,
    /// `SPEC-ORC-015`), and reason bit 12 when an alternate leg in use is past its borrow age (`REQ-ORACLE-090`).
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

    /// @dev `inGrace` and `graceEndsAt` from the recovery window and the sequencer grace (`REQ-ORACLE-034`,
    /// `REQ-ORACLE-099`).
    /// @custom:spec REQ-ORACLE-034, REQ-ORACLE-099
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
