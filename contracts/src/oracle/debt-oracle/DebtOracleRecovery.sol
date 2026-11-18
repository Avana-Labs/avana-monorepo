// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAggregatorV3} from "../../interfaces/external/chainlink/IAggregatorV3.sol";
import {DebtOracleEvaluation} from "./DebtOracleEvaluation.sol";
import {DebtEvaluation, LegRead, ReadStatus, RouteRead} from "./types/DebtEvaluation.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title DebtOracleRecovery
/// @notice Recovery evidence from Chainlink source timestamps, evaluated by `poke()` before it records its rounds.
abstract contract DebtOracleRecovery is DebtOracleEvaluation {
    /// @dev A half-open interval `[start, end)`; `exists` is false for an empty or absent one.
    struct Span {
        bool exists;
        uint64 start;
        uint64 end;
    }

    /// @dev The new `recoveredAt` when the both-stale interval lasted `cachedWindow` and ended after the stored one.
    function _evidence(
        DebtEvaluation memory e
    ) internal view returns (bool found, uint64 recoveredAtNew) {
        (bool okP, Span memory p) = _routeSpan(e.routes[0], 0);
        if (!okP || !p.exists) return (false, 0);
        (bool okA, Span memory a) = _routeSpan(e.routes[1], 1);
        if (!okA || !a.exists) return (false, 0);
        uint64 lo = p.start > a.start ? p.start : a.start;
        uint64 hi = p.end < a.end ? p.end : a.end;
        if (hi <= lo || hi - lo < e.cachedWindow || hi <= e.recoveredAt) return (false, 0);
        recoveredAtNew = hi < block.timestamp ? hi : SafeCast.toUint64(block.timestamp);
        return (true, recoveredAtNew);
    }

    /// @dev The stale interval of one route; `ok` false for an invalid route or an unusable lookup.
    function _routeSpan(
        RouteRead memory route,
        uint256 r
    ) internal view returns (bool ok, Span memory span) {
        if (route.status == ReadStatus.Stale) {
            return (true, Span({exists: true, start: route.staleFrom, end: SafeCast.toUint64(block.timestamp)}));
        }
        if (route.status != ReadStatus.Valid) return (false, span);
        (bool ok0, Span memory g0) = _legGap(route.legs[0], r, 0);
        if (!ok0) return (false, span);
        if (route.legCount == 1) return (true, g0);
        (bool ok1, Span memory g1) = _legGap(route.legs[1], r, 1);
        if (!ok1) return (false, span);
        return (true, _merge(g0, g1));
    }

    function _merge(
        Span memory g0,
        Span memory g1
    ) internal pure returns (Span memory) {
        if (!g0.exists) return g1;
        if (!g1.exists) return g0;
        if (g0.start < g1.end && g1.start < g0.end) {
            return Span({
                exists: true, start: g0.start < g1.start ? g0.start : g1.start, end: g0.end > g1.end ? g0.end : g1.end
            });
        }
        return g0.end >= g1.end ? g0 : g1;
    }

    /// @dev The last gap `[prev + feedMaxAge + 1, updatedAt)` of one valid leg, or none.
    function _legGap(
        LegRead memory leg,
        uint256 r,
        uint256 j
    ) internal view returns (bool ok, Span memory gap) {
        Seen storage seen = _s().seen[r][j];
        uint64 seenAt = seen.updatedAt;
        if (
            seen.feed != leg.feed || leg.roundId == seen.roundId || leg.updatedAt <= seenAt
                || leg.updatedAt - seenAt <= leg.maxAge
        ) return (true, gap);
        (bool usable, uint64 prev) = _previousRound(leg, seenAt);
        if (!usable) return (false, gap);
        // prev < updatedAt <= now < 2^64 and maxAge < 2^33, so the start fits in 64 bits.
        uint256 start = uint256(prev) + leg.maxAge + 1;
        if (start >= leg.updatedAt) return (true, gap);
        return (true, Span({exists: true, start: SafeCast.toUint64(start), end: leg.updatedAt}));
    }

    /// @dev `updatedAt` of the previous round; on a phase's first round, the previous phase's last, else `seen`.
    function _previousRound(
        LegRead memory leg,
        uint64 seenAt
    ) internal view returns (bool usable, uint64 prev) {
        uint256 aggregatorRound = uint256(leg.roundId) & type(uint64).max;
        if (aggregatorRound == 0) return (false, 0);
        if (aggregatorRound == 1) {
            (bool ok, uint64 last) = _previousPhaseLast(leg, SafeCast.toUint16(uint256(leg.roundId) >> 64));
            prev = ok ? last : seenAt;
        } else {
            bool ok;
            (ok,,,, prev,) = _readRound(leg.feed, abi.encodeCall(IAggregatorV3.getRoundData, (leg.roundId - 1)));
            if (!ok) return (false, 0);
        }
        usable = prev != 0 && prev < leg.updatedAt;
    }

    function _previousPhaseLast(
        LegRead memory leg,
        uint16 phaseId
    ) internal view returns (bool ok, uint64 last) {
        if (phaseId <= 1) return (false, 0);
        (bool okAgg, address aggregator) = _readPhaseAggregator(leg.feed, phaseId - 1);
        if (!okAgg || aggregator == address(0)) return (false, 0);
        bool okRound;
        (okRound,,,, last,) = _readLatest(aggregator);
        ok = okRound && last != 0 && last < leg.updatedAt;
    }
}
