// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../types/PriceState.sol";
import {LPOracleRecovery} from "./LPOracleRecovery.sol";
import {Evaluation, LegEval, RouteEval, TokenEval} from "./LPOracleTypes.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// Every external call of the LPOracle is a static call (STATICCALL, or a delegatecall into its own logic, which makes
// only static calls), so no call can reenter and reorder the events emitted after it (REQ-ORACLE-025).
// forge-lint: disable-start(reentrancy-events)
/// @title LPOraclePoke
/// @notice The writing call: `poke()` evaluates the market with the code of every view, verifies the token decimals
/// (`REQ-ORACLE-107`) and stores, in the order of `REQ-ORACLE-026`, the decimals result, the route versions, the failure
/// and disagreement timers, the accepted price, the outage latch, the `seen` rounds, the grace window and the
/// checkpoint, emitting an event for each write.
/// @dev Makes only static calls, takes no lock and is permissionless. Reverts `InsufficientGas(gasleft(), pokeMinGas)`
/// at the implementation's entry before any call or write (`LPOracle.poke`); every read inside follows the pre-call
/// gas check, so a call starved of gas reverts and commits no failure, timer or latch (`REQ-ORACLE-024`). Example: a
/// market Cached since
/// `failedSince = 1,762,650,000` keeps that timer across a standby switch; the poke that observes the switch restarts
/// `disagreeSince` at `now` if a token disagrees on the new routes and emits `PriceRouteVersionObserved`.
/// @custom:spec REQ-ORACLE-107, REQ-ORACLE-024, REQ-ORACLE-025, REQ-ORACLE-026, REQ-ORACLE-027, REQ-ORACLE-028, REQ-ORACLE-029, REQ-ORACLE-030, REQ-ORACLE-031, REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-035, REQ-ORACLE-062, REQ-ORACLE-065, REQ-ORACLE-066, REQ-ORACLE-088, REQ-ORACLE-095, REQ-ORACLE-103
abstract contract LPOraclePoke is LPOracleRecovery {
    /// @dev `poke()`: evaluate, then write in the specified order. The caller checks `pokeMinGas` at entry.
    /// @custom:spec REQ-ORACLE-026
    function _poke() internal returns (PriceState) {
        Layout storage $ = _s();
        Evaluation memory e = _evaluatePoke();
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

    /// @dev `REQ-ORACLE-107`: a verified poke stores `decimalsCheckedAt = now` and clears a stored mismatch
    /// (`TokenDecimalsRestored`); a failed verification marks the configuration invalid (`TokenDecimalsMismatch` when it
    /// was valid) and keeps the time of the last successful one. The stored decimals are never replaced.
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

    /// @dev `REQ-ORACLE-095`: on a route-version change, `disagreeSince = now` if some token disagrees and 0
    /// otherwise, the new versions stored and `PriceRouteVersionObserved` emitted per changed token.
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

    /// @dev `REQ-ORACLE-027`: failed with no recorded start → `failedSince = min(S_ts, now)`; not failed → 0.
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

    /// @dev `REQ-ORACLE-028`: a new disagreement stores `now`; agreement (or a failed market) clears it.
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

    /// @dev `DisagreementRecorded(now, primary values, alternate values)`.
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

    /// @dev `REQ-ORACLE-029`: store `{price8, min t_i, v}` only when Live and newer than the stored timestamp.
    function _writeAccepted(
        Evaluation memory e
    ) private {
        Layout storage $ = _s();
        if (e.state != PriceState.Live || e.servedUpdatedAt <= $.accepted.updatedAt) return;
        _storeAccepted(e);
        emit PriceAccepted(SafeCast.toInt256(e.fresh), e.servedUpdatedAt, e.prices);
    }

    /// @dev Stores the evaluation's fresh price, timestamp and valuation vector as the accepted price.
    /// @custom:spec REQ-ORACLE-029, REQ-ORACLE-059, REQ-ORACLE-103
    function _storeAccepted(
        Evaluation memory e
    ) internal {
        Layout storage $ = _s();
        // fresh < 2^255 (SPEC-ORC-008 bounds), so the signed value is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        $.accepted.answer = int256(e.fresh);
        $.accepted.updatedAt = e.servedUpdatedAt;
        uint256 n = e.prices.length;
        delete $.accepted.prices;
        for (uint256 i = 0; i < n; ++i) {
            // Valuation prices are route values of at most MAX_ROUTE_ANSWER = 10^12 (LPPriceMath.lpPrice checked).
            // forge-lint: disable-next-line(unsafe-typecast)
            $.accepted.prices.push(uint128(e.prices[i]));
        }
        $.acceptedBlock = SafeCast.toUint64(block.number);
    }

    /// @dev `REQ-ORACLE-030`: latch only when a failed token has both routes `Stale` and `now >= staleAt_i +
    /// cachedWindow`; never from a caught error, a failed configuration read or `failedSince`.
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

    /// @dev `REQ-ORACLE-031`: every leg read with decodable data records its aggregator, round and timestamp.
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
                    // One record per leg in force; the loop is bounded by 8 tokens x 2 routes x 2 legs.
                    $.seen[i][r][l] = Seen({feed: leg.feed, roundId: leg.roundId, updatedAt: leg.updatedAt});
                }
            }
        }
    }

    /// @dev `REQ-ORACLE-032`: start one grace window, clear the latch and emit `GraceStarted`.
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

    /// @dev `min(max over every leg of the quote routes of updatedAt, now)` (`REQ-ORACLE-032` (c)).
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

    /// @dev `REQ-ORACLE-088`: copy the accepted price once `now >= checkpoint.at + CHECKPOINT_INTERVAL`.
    function _writeCheckpoint() private {
        Layout storage $ = _s();
        if (block.timestamp < uint256($.checkpoint.at) + CHECKPOINT_INTERVAL) return;
        _storeCheckpoint();
    }

    /// @dev Copies the accepted price with the block time and emits `PriceCheckpointed`.
    /// @custom:spec REQ-ORACLE-088, REQ-ORACLE-059
    function _storeCheckpoint() internal {
        Layout storage $ = _s();
        // The accepted price is a positive price8 below 2^128 (SPEC-ORC-008 bounds at 10^d <= 10^18 units).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 price8 = uint128(uint256($.accepted.answer));
        $.checkpoint = Checkpoint({price8: price8, at: _now64()});
        emit PriceCheckpointed(price8, _now64());
    }

    /// @dev `REQ-ORACLE-035`: `PriceStateChanged` and `RouteChanged`, then the stored last state and routes.
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
