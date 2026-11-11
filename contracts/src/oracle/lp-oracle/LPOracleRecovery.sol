// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAggregatorProxy} from "../../interfaces/external/chainlink/IAggregatorProxy.sol";
import {IAggregatorV3} from "../../interfaces/external/chainlink/IAggregatorV3.sol";
import {LPOracleCalls} from "./LPOracleCalls.sol";
import {LPOracleEval} from "./LPOracleEval.sol";
import {Evaluation, LPOracleCodes, LegEval, RouteEval} from "./LPOracleTypes.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LPOracleRecovery
/// @notice Recovery evidence from Chainlink source timestamps (`SPEC-ORC-014`, `REQ-ORACLE-089`): whether an outage
/// that started and ended between two pokes reached Expired, and when it ended.
/// @dev Run by `poke()` only, when the market is not failed, before `seen` is overwritten. For each leg whose `seen`
/// aggregator is the leg in force, whose round changed and whose new round is more than `feedMaxAge` after the
/// recorded one, the previous round is read (`getRoundData(roundId - 1)`, or on the first round of a phase the last
/// round of the previous phase, then the recorded timestamp); the leg's gap is `[prev + feedMaxAge + 1, updatedAt)`.
/// A valid route's stale interval is the union of its legs' gaps when they overlap, else the later gap; a Stale
/// route's is `[staleFrom, now)`; an `Invalid` or `Error` route or an unusable lookup gives the token no evidence.
/// Token i's both-stale interval is the intersection of its two routes' intervals. Example: primary gap
/// `[1,084,601, 1,200,000)` and alternate gap `[1,134,201, 1,190,000)` give `B = [1,134,201, 1,190,000)`, 55,799 s,
/// so with `cachedWindow = 3,600` the outage reached Expired and `recoveredAt = 1,190,000`.
/// @custom:spec SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-065, REQ-ORACLE-075, REQ-ORACLE-089, Q-129, Q-154, Q-272
abstract contract LPOracleRecovery is LPOracleEval {
    /// @dev A half-open interval `[start, end)`; `any` is false for an empty one.
    struct Span {
        bool any;
        uint64 start;
        uint64 end;
    }

    /// @dev Whether some token's both-stale interval lasts at least `cachedWindow` and ends after the stored
    /// `recoveredAt`, and then `recoveredAt_new`: the latest such end over every token, capped at `now`.
    /// @custom:spec SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033
    function _recoveryEvidence(
        Evaluation memory e
    ) internal view returns (bool found, uint64 recovered) {
        uint64 stored = _s().recoveredAt;
        uint64 latest = 0;
        uint256 n = e.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            Span memory b = _bothStale(e.tokens[i].routes, i);
            if (!b.any || b.end <= stored) continue;
            if (b.end - b.start >= e.cfg.cachedWindow) found = true;
            if (b.end > latest) latest = b.end;
        }
        if (!found) return (false, 0);
        recovered = latest < block.timestamp ? latest : _now64();
    }

    /// @dev `B_i = S_primary ∩ S_alternate`; empty when either route gives no evidence.
    function _bothStale(
        RouteEval[2] memory routes,
        uint256 i
    ) private view returns (Span memory b) {
        (bool usableP, Span memory p) = _routeSpan(routes[0], i, 0);
        if (!usableP || !p.any) return b;
        (bool usableA, Span memory a) = _routeSpan(routes[1], i, 1);
        if (!usableA || !a.any) return b;
        b.start = p.start > a.start ? p.start : a.start;
        b.end = p.end < a.end ? p.end : a.end;
        b.any = b.start < b.end;
    }

    /// @dev `S_r` of one route; `usable` is false for an `Invalid` or `Error` route or an unusable lookup.
    function _routeSpan(
        RouteEval memory route,
        uint256 i,
        uint256 r
    ) private view returns (bool usable, Span memory s) {
        if (route.status == LPOracleCodes.STALE) {
            s.start = route.staleFrom;
            s.end = _now64();
            s.any = s.start < s.end;
            return (true, s);
        }
        if (route.status != LPOracleCodes.VALID) return (false, s);
        Span memory g0;
        Span memory g1;
        (usable, g0) = _legGap(route.legs[0], _s().seen[i][r][0]);
        if (!usable) return (false, s);
        if (route.legCount == 2) {
            (usable, g1) = _legGap(route.legs[1], _s().seen[i][r][1]);
            if (!usable) return (false, s);
        }
        return (true, _union(g0, g1));
    }

    /// @dev The union of two gaps when they overlap, else the gap with the later end.
    function _union(
        Span memory a,
        Span memory b
    ) private pure returns (Span memory) {
        if (!a.any) return b;
        if (!b.any) return a;
        uint64 lo = a.start > b.start ? a.start : b.start;
        uint64 hi = a.end < b.end ? a.end : b.end;
        if (lo < hi) {
            return Span({any: true, start: a.start < b.start ? a.start : b.start, end: a.end > b.end ? a.end : b.end});
        }
        return a.end > b.end ? a : b;
    }

    /// @dev The leg's last gap `[prev + feedMaxAge + 1, updatedAt)`; no gap for a leg not looked up.
    function _legGap(
        LegEval memory leg,
        Seen storage seen
    ) private view returns (bool usable, Span memory g) {
        uint64 seenAt = seen.updatedAt;
        if (
            seen.feed != leg.feed || seen.roundId == leg.roundId || leg.updatedAt <= seenAt
                || leg.updatedAt - seenAt <= leg.maxAge
        ) return (true, g);
        uint64 prev = 0;
        (usable, prev) = _previousRound(leg, seenAt);
        if (!usable) return (false, g);
        uint256 start = uint256(prev) + leg.maxAge + 1;
        if (start < leg.updatedAt) {
            g = Span({any: true, start: SafeCast.toUint64(start), end: leg.updatedAt});
        }
    }

    /// @dev The previous round's timestamp (`SPEC-ORC-014`, `REQ-ORACLE-089`): `getRoundData(roundId - 1)`; on the
    /// first round of a phase, the previous phase aggregator's `latestRoundData()`, then the recorded `seen` time.
    /// @custom:spec SPEC-ORC-014, REQ-ORACLE-089, REQ-ORACLE-075
    function _previousRound(
        LegEval memory leg,
        uint64 seenAt
    ) private view returns (bool usable, uint64 prev) {
        uint80 id = leg.roundId;
        // A proxy round id is phaseId << 64 | aggregatorRoundId (REQ-ORACLE-089): the truncations select the parts.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint64(id) == 1) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint16 phase = uint16(id >> 64);
            if (phase > 1) {
                (usable, prev) = _previousPhase(leg.feed, phase - 1);
                if (usable && prev != 0 && prev < leg.updatedAt) return (true, prev);
            }
            if (seenAt != 0 && seenAt < leg.updatedAt) return (true, seenAt);
            return (false, 0);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint64(id) == 0) return (false, 0);
        bytes memory ret;
        (usable, ret) = LPOracleCalls.staticRead(
            leg.feed, FEED_CALL_GAS, abi.encodeCall(IAggregatorV3.getRoundData, (id - 1)), ROUND_LENGTH
        );
        uint256 updatedAt = 0;
        (usable,,,, updatedAt) = _decodeRound(usable, ret);
        if (!usable || updatedAt == 0 || updatedAt >= leg.updatedAt) return (false, 0);
        prev = SafeCast.toUint64(updatedAt);
    }

    /// @dev `latestRoundData().updatedAt` of the proxy's aggregator of `phase`; `usable` false on any failed read.
    function _previousPhase(
        address proxy,
        uint16 phase
    ) private view returns (bool usable, uint64 prev) {
        bytes memory ret;
        (usable, ret) = LPOracleCalls.staticRead(
            proxy, FEED_CALL_GAS, abi.encodeCall(IAggregatorProxy.phaseAggregators, (phase)), WORD
        );
        uint256 aggregator = 0;
        if (usable) (usable, aggregator) = LPOracleCalls.uintAt(ret, 0, type(uint160).max);
        if (!usable || aggregator == 0) return (false, 0);
        uint256 updatedAt = 0;
        // Bounded to 160 bits by the check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        (usable,,,, updatedAt) = _latestRound(address(uint160(aggregator)));
        if (!usable || updatedAt > type(uint64).max) return (false, 0);
        prev = SafeCast.toUint64(updatedAt);
    }
}
