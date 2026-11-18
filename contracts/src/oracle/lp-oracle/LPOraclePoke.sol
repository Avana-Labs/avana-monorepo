// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../types/PriceState.sol";
import {LPOracleRecovery} from "./LPOracleRecovery.sol";
import {Evaluation, LPOracleCodes, LegEval, RouteEval, TokenEval} from "./LPOracleTypes.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// Every external call is a static call or a delegatecall into this feed's own logic, so none can reenter.
// forge-lint: disable-start(reentrancy-events)
/// @title LPOraclePoke
/// @notice The writing call: `poke()` evaluates the market and stores price state, timers, latch and checkpoint.
/// @dev A call starved of gas reverts, so it never commits a failure, timer or latch.
abstract contract LPOraclePoke is LPOracleRecovery {
    /// @dev The caller checks `pokeMinGas` at entry.
    function _poke() internal returns (PriceState) {
        Layout storage $ = _s();
        Evaluation memory e = _evaluatePoke();
        // Inside a pool callback, write nothing, so a caller cannot move a timer from inside a callback.
        if ((e.reasons & LPOracleCodes.POOL_REENTRANCY_LOCKED) != 0) return e.state;
        // Recovery evidence reads the `seen` rounds before this poke overwrites them.
        bool evidence = false;
        uint64 recovered = 0;
        if (!e.failed) (evidence, recovered) = _recoveryEvidence(e);
        bool wasLatched = $.expiredLatched;
        _writeDecimals(e);
        _writeVersions(e);
        _writeFailure(e);
        if (!e.versionChanged) _writeDisagreement(e);
        if (e.quoteCapped) emit QuoteChangeCapped($.accepted.answer, SafeCast.toInt256(e.fresh));
        _writeAccepted(e);
        _writeLatch(e);
        _writeSeen(e);
        if (!e.failed && (wasLatched || evidence)) _startGrace(e, wasLatched, evidence, recovered);
        _writeCheckpoint();
        _writeEvents(e);
        if (e.cfg.ok) $.lastCachedWindow = e.cfg.cachedWindow;
        return e.state;
    }

    /// @dev A failed verification keeps the time of the last successful one.
    function _writeDecimals(
        Evaluation memory e
    ) internal {
        Layout storage $ = _s();
        if (!e.decimalsMismatch) {
            $.decimalsCheckedAt = e.decimalsCheckedAt;
            if (!$.decimalsInvalid) return;
            $.decimalsInvalid = false;
            emit TokenDecimalsRestored(e.decimalsCheckedAt);
            return;
        }
        if ($.decimalsInvalid) return;
        $.decimalsInvalid = true;
        uint8 i = e.decimalsToken;
        emit TokenDecimalsMismatch(i, $.tokenDecimals[i], e.decimalsRead, e.decimalsReadable);
    }

    /// @dev On a route-version change, stores the versions and restarts or clears `disagreeSince`.
    function _writeVersions(
        Evaluation memory e
    ) internal {
        if (!e.versionChanged) return;
        Layout storage $ = _s();
        uint256 n = e.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            uint64 current = e.tokens[i].version;
            uint64 previous = $.routeVersion[i];
            if (current == previous) continue;
            $.routeVersion[i] = current;
            emit PriceRouteVersionObserved(SafeCast.toUint8(i), previous, current);
        }
        uint64 since = $.disagreeSince;
        if (e.disagreeing) {
            $.disagreeSince = _now64();
            _emitDisagreement(e);
        } else if (since != 0) {
            $.disagreeSince = 0;
            emit DisagreementCleared(since, _now64());
        }
    }

    /// @dev Sets `failedSince` on a new failure (from the stale start, never after now); clears it on recovery.
    function _writeFailure(
        Evaluation memory e
    ) internal {
        Layout storage $ = _s();
        uint64 since = $.failedSince;
        if (e.failed && since == 0) {
            uint64 start = _now64();
            if (e.hasStaleStart && e.staleStart < start) start = e.staleStart;
            $.failedSince = start;
            emit FailureRecorded(start, e.reasons);
        } else if (!e.failed && since != 0) {
            $.failedSince = 0;
            emit FailureCleared(since, _now64());
        }
    }

    function _writeDisagreement(
        Evaluation memory e
    ) internal {
        Layout storage $ = _s();
        uint64 since = $.disagreeSince;
        if (e.disagreeing && since == 0) {
            $.disagreeSince = _now64();
            _emitDisagreement(e);
        } else if (!e.disagreeing && since != 0) {
            $.disagreeSince = 0;
            emit DisagreementCleared(since, _now64());
        }
    }

    function _emitDisagreement(
        Evaluation memory e
    ) private {
        uint256 n = e.tokens.length;
        uint256[] memory primary = new uint256[](n);
        uint256[] memory alternate = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            primary[i] = e.tokens[i].routes[0].value;
            alternate[i] = e.tokens[i].routes[1].value;
        }
        emit DisagreementRecorded(_now64(), primary, alternate);
    }

    /// @dev Stores the fresh price when Live and the served timestamp advanced, or the price moved at the same one.
    function _writeAccepted(
        Evaluation memory e
    ) private {
        Layout storage $ = _s();
        if (e.state != PriceState.Live) return;
        uint64 at = $.accepted.updatedAt;
        if (e.servedUpdatedAt < at) return;
        // fresh < 2^255, so the signed comparison is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (e.servedUpdatedAt == at && int256(e.fresh) == $.accepted.answer) return;
        _storeAccepted(e);
        emit PriceAccepted(SafeCast.toInt256(e.fresh), e.servedUpdatedAt, e.prices);
    }

    function _storeAccepted(
        Evaluation memory e
    ) internal {
        Layout storage $ = _s();
        // fresh < 2^255, so the signed value is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        $.accepted.answer = int256(e.fresh);
        $.accepted.updatedAt = e.servedUpdatedAt;
        uint256 n = e.prices.length;
        delete $.accepted.prices;
        for (uint256 i = 0; i < n; ++i) {
            // Valuation prices are at most MAX_ROUTE_ANSWER < 2^128.
            // forge-lint: disable-next-line(unsafe-typecast)
            $.accepted.prices.push(uint128(e.prices[i]));
        }
        $.acceptedBlock = SafeCast.toUint64(block.number);
    }

    /// @dev Latches only from source timestamps: a token with both routes stale for `cachedWindow`.
    function _writeLatch(
        Evaluation memory e
    ) private {
        Layout storage $ = _s();
        if (!e.failed || !e.cfg.ok || $.expiredLatched) return;
        uint256 n = e.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            TokenEval memory t = e.tokens[i];
            if (!t.bothStale || block.timestamp < uint256(t.staleAt) + e.cfg.cachedWindow) continue;
            $.expiredLatched = true;
            emit OutageExpiredLatched(SafeCast.toUint8(i), t.staleAt, _now64());
            return;
        }
    }

    function _writeSeen(
        Evaluation memory e
    ) internal {
        Layout storage $ = _s();
        uint256 n = e.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            for (uint256 r = 0; r < 2; ++r) {
                RouteEval memory route = e.tokens[i].routes[r];
                for (uint256 l = 0; l < route.legCount; ++l) {
                    LegEval memory leg = route.legs[l];
                    if (!leg.decoded) continue;
                    $.seen[i][r][l] = Seen({feed: leg.feed, roundId: leg.roundId, updatedAt: leg.updatedAt});
                }
            }
        }
    }

    function _startGrace(
        Evaluation memory e,
        bool wasLatched,
        bool evidence,
        uint64 recovered
    ) private {
        Layout storage $ = _s();
        uint64 at = 0;
        if (wasLatched && e.versionChanged) at = _now64();
        else if (evidence) at = recovered;
        else at = _newestLegInUse(e);
        $.recoveredAt = at;
        $.expiredLatched = false;
        emit GraceStarted(at, at + e.cfg.graceDuration, wasLatched);
    }

    function _newestLegInUse(
        Evaluation memory e
    ) private view returns (uint64 newest) {
        uint256 n = e.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            TokenEval memory t = e.tokens[i];
            RouteEval memory route = t.routes[t.used - 1];
            for (uint256 l = 0; l < route.legCount; ++l) {
                if (route.legs[l].updatedAt > newest) newest = route.legs[l].updatedAt;
            }
        }
        if (newest > block.timestamp) newest = _now64();
    }

    function _writeCheckpoint() private {
        Layout storage $ = _s();
        if (block.timestamp < uint256($.checkpoint.at) + CHECKPOINT_INTERVAL) return;
        _storeCheckpoint();
    }

    function _storeCheckpoint() internal {
        Layout storage $ = _s();
        // A price above 2^128 - 1 is stored saturated rather than truncated.
        uint256 answer = SafeCast.toUint256($.accepted.answer);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 price8 = uint128(answer > type(uint128).max ? type(uint128).max : answer);
        $.checkpoint = Checkpoint({price8: price8, at: _now64()});
        emit PriceCheckpointed(price8, _now64());
    }

    function _writeEvents(
        Evaluation memory e
    ) private {
        Layout storage $ = _s();
        PriceState previous = PriceState($.lastState);
        if (previous != e.state) {
            emit PriceStateChanged(previous, e.state, e.reasons, e.servedUpdatedAt);
            $.lastState = uint8(e.state);
        }
        uint256 n = e.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            uint8 used = e.tokens[i].used;
            uint8 last = $.lastRoute[i];
            if (used == last) continue;
            emit RouteChanged(SafeCast.toUint8(i), last, used);
            $.lastRoute[i] = used;
        }
    }
}
// forge-lint: disable-end(reentrancy-events)
