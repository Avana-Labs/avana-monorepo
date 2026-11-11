// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPPriceMath} from "../../src/oracle/lp-oracle/LPPriceMath.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {LPPriceMathHarness} from "../utils/harness/LPPriceMathHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LPPriceMathFuzzTest
/// @notice Stateless fuzzing of every LPPriceMath formula over the whole input domain, inside and outside the listing
/// bounds of 2.10: rounding direction of every floor and ceiling, fail-closed results instead of reverts outside the
/// bounds (signed answers, malformed vectors, oversize values), symmetry and monotonicity, the fixed-point USD level,
/// and the state properties of the served prices, including a disagreement priced from real full-range compositions.
/// @dev Calls go through `LPPriceMathHarness`, so a revert inside the library fails the test.
contract LPPriceMathFuzzTest is AvanaTest {
    uint256 internal constant MAX_ROUTE = 1e12;
    uint256 internal constant MAX_TOKENS = 8;
    uint256 internal constant SAT = type(uint256).max;
    uint256 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    uint256 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    LPPriceMathHarness internal m;

    function setUp() public {
        m = new LPPriceMathHarness();
    }

    // ─── SPEC-ORC-001, SPEC-ORC-002 ───

    // TEST-070 verifies: SPEC-ORC-001, REQ-ORACLE-012, REQ-ORACLE-002, ATTACK-055
    // Sources: MATH-UO-48a, MATH-UO-15c, MATH-UO-58a
    function testFuzz_TEST_070_normalizeAnswerRoundsDownAndFailsClosed(
        int256 answer,
        uint8 decimals
    ) public view {
        uint256 n = m.normalizeAnswer(answer, decimals);
        if (answer <= 0 || uint256(answer) >= 2 ** 128) {
            assertEq(n, 0, "outside (0, 2^128): 0");
            return;
        }
        uint256 a = uint256(answer);
        if (decimals <= 8) {
            assertEq(n, a * 10 ** (8 - decimals), "exact at 8 or fewer decimals");
            assertGe(n, 1, "never 0");
        } else if (decimals - 8 <= 77) {
            uint256 unit = 10 ** (decimals - 8);
            assertLe(n * unit, a, "never above the feed");
            assertGt((n + 1) * unit, a, "less than one unit below");
        } else {
            assertEq(n, 0, "beyond 10^77 every answer floors to 0");
        }
    }

    // TEST-070 verifies: SPEC-ORC-002, REQ-ORACLE-012, REQ-ORACLE-049
    // Sources: MATH-UO-48b, MATH-UO-14, MATH-UO-58b
    function testFuzz_TEST_070_routeValueRoundsDownWithoutOverflow(
        int256 answerA,
        uint8 decimalsA,
        int256 answerB,
        uint8 decimalsB
    ) public view {
        // Half the runs inside the answer bound, where the floor is checked.
        if (decimalsA % 2 == 0) {
            answerA = int256(bound(uint256(answerA < 0 ? -(answerA + 1) : answerA), 1, 2 ** 128 - 1));
            answerB = int256(bound(uint256(answerB < 0 ? -(answerB + 1) : answerB), 1, 2 ** 128 - 1));
        }
        uint256 r = m.routeValue2(answerA, decimalsA, answerB, decimalsB);
        uint256 sum = uint256(decimalsA) + decimalsB;
        bool okA = answerA > 0 && uint256(answerA) < 2 ** 128;
        bool okB = answerB > 0 && uint256(answerB) < 2 ** 128;
        if (!okA || !okB || sum < 8) {
            assertEq(r, 0, "invalid leg or fA + fB < 8: 0");
            return;
        }
        uint256 product = uint256(answerA) * uint256(answerB);
        uint256 k = sum - 8;
        if (k <= 77) assertEq(r, product / 10 ** k, "floor(aA * aB / 10^k)");
        else assertEq(r, 0, "product below 10^77 floors to 0");
    }

    // TEST-070 verifies: SPEC-ORC-002
    function testFuzz_TEST_070_routeTimestampIsOldest(
        uint64 a,
        uint64 b
    ) public view {
        uint64 t = m.routeTimestamp(a, b);
        assertTrue(t <= a && t <= b && (t == a || t == b), "oldest input");
    }

    // ─── SPEC-ORC-003, SPEC-ORC-020, REQ-ORACLE-042 ───

    // TEST-039 verifies: SPEC-ORC-003, REQ-ORACLE-008, ATTACK-054, Q-184
    // Sources: MATH-UO-24b, MATH-UO-24c, MATH-UO-60c
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_TEST_039_agreementExactSymmetricMonotone(
        uint256 p,
        uint256 b,
        uint16 t,
        uint16 t2
    ) public view {
        if (t % 4 != 0) {
            p = bound(p, 0, MAX_ROUTE + 1);
            b = bound(b, 0, MAX_ROUTE + 1);
        }
        bool agree = m.routesAgree(p, b, t);
        bool inBounds = p >= 1 && b >= 1 && p <= MAX_ROUTE && b <= MAX_ROUTE;
        uint256 diff = p > b ? p - b : b - p;
        uint256 lo = p < b ? p : b;
        assertEq(agree, inBounds && diff * 1e4 <= uint256(t) * lo, "exact cross-multiplied rule, fail closed");
        assertEq(agree, m.routesAgree(b, p, t), "symmetric");
        if (agree && t2 >= t) assertTrue(m.routesAgree(p, b, t2), "a wider tolerance never disagrees more");
        if (agree) assertLe(m.deviationBps(p, b), t, "the floored deviation never exceeds an agreeing T");
    }

    // TEST-276 verifies: SPEC-ORC-020, REQ-ORACLE-100
    // Sources: MATH-UO-54a, MATH-UO-54b
    function testFuzz_TEST_276_secondSourceSymmetricAndNeedsValidity(
        uint256 q,
        uint256 s,
        uint16 t,
        bool valid
    ) public view {
        q = bound(q, 0, MAX_ROUTE + 1);
        s = bound(s, 0, MAX_ROUTE + 1);
        bool confirmed = m.secondSourceAgrees(valid, q, s, t);
        assertEq(confirmed, m.secondSourceAgrees(valid, s, q, t), "symmetric");
        assertEq(confirmed, valid && m.routesAgree(q, s, t), "same rule as the agreement check, gated on validity");
    }

    // TEST-039 verifies: REQ-ORACLE-042
    // Sources: MATH-UO-60a, MATH-UO-60b
    function testFuzz_TEST_039_deviationBpsNeverReverts(
        uint256 x,
        uint256 y
    ) public view {
        uint256 d = m.deviationBps(x, y);
        uint256 lo = x < y ? x : y;
        uint256 diff = x > y ? x - y : y - x;
        if (lo == 0 || diff > SAT / 1e4) assertEq(d, SAT, "unreadable or not representable: saturated");
        else assertEq(d, diff * 1e4 / lo, "exact floor");
    }

    // ─── SPEC-ORC-004 ───

    // TEST-167 verifies: SPEC-ORC-004, REQ-ORACLE-009, Q-177
    // Sources: MATH-UO-19a, MATH-UO-19b, MATH-UO-19c
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_TEST_167_ceilingNeverRaisesAndIsMonotone(
        uint256 q1,
        uint256 q2,
        bool stable
    ) public view {
        if (q1 > q2) (q1, q2) = (q2, q1);
        uint256 v1 = m.valuationPrice(q1, stable);
        uint256 v2 = m.valuationPrice(q2, stable);
        assertLe(v1, q1, "never raises");
        assertLe(v1, v2, "monotone");
        if (!stable || q1 <= 1e8) assertEq(v1, q1, "no-op at or below $1 and for a non-stable");
        if (stable) assertLe(v2, 1e8, "a stable is never valued above $1");
    }

    // ─── SPEC-ORC-008 ───

    // TEST-217 verifies: SPEC-ORC-008, REQ-ORACLE-012, REQ-ORACLE-103, INV-055, INV-078
    // Sources: MATH-UO-51a, AMM-A3f, MATH-UO-14d, MATH-UO-64
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_TEST_217_lpPriceNeverAboveHoldingsAndBoundedError(
        uint256 seed,
        uint256 n
    ) public view {
        n = bound(n, 2, MAX_TOKENS);
        (uint256[] memory a, uint256[] memory v, uint8[] memory d) = _vectors(seed, n);
        (bool valid, uint256 price8) = m.lpPrice(a, v, d);
        assertTrue(valid, "inside the bounds");
        uint256 exactScaled;
        uint256 slackScaled;
        for (uint256 i = 0; i < n; ++i) {
            exactScaled += a[i] * v[i] * 10 ** (18 - d[i]);
            slackScaled += v[i] * 10 ** (18 - d[i]) + 1e18;
        }
        assertGe(price8, 1, "at least 1");
        assertLt(price8, 2 ** 171, "below 2^171");
        if (exactScaled >= 1e18) assertLe(price8 * 1e18, exactScaled, "never above the holdings at the oracle prices");
        else assertEq(price8, 1, "worth less than one unit: 1");
        assertGe(price8 * 1e18 + slackScaled, exactScaled, "below by at most sum(v_i / 10^d_i + 1)");
    }

    // TEST-036 verifies: SPEC-ORC-008, REQ-ORACLE-013, INV-055
    // Sources: MATH-UO-18 (no dependence on token order), MATH-UO-52 (monotone in each price)
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_TEST_036_lpPriceSymmetricAndMonotone(
        uint256 seed,
        uint256 n,
        uint256 i,
        uint256 j,
        uint256 bump
    ) public view {
        n = bound(n, 2, MAX_TOKENS);
        i = bound(i, 0, n - 1);
        j = bound(j, 0, n - 1);
        bump = bound(bump, 0, MAX_ROUTE);
        (uint256[] memory a, uint256[] memory v, uint8[] memory d) = _vectors(seed, n);
        (, uint256 price8) = m.lpPrice(a, v, d);
        (a[i], a[j]) = (a[j], a[i]);
        (v[i], v[j]) = (v[j], v[i]);
        (d[i], d[j]) = (d[j], d[i]);
        (, uint256 swapped) = m.lpPrice(a, v, d);
        assertEq(swapped, price8, "token order does not matter");
        v[i] = bound(v[i] + bump, v[i], MAX_ROUTE);
        (, uint256 higher) = m.lpPrice(a, v, d);
        assertGe(higher, price8, "a higher price never lowers the value of the same holdings");
        a[j] = bound(a[j] + bump, a[j], 2 ** 128 - 1);
        (, uint256 more) = m.lpPrice(a, v, d);
        assertGe(more, higher, "more of a token never lowers the value");
    }

    // TEST-036 verifies: SPEC-ORC-008, REQ-ORACLE-103, REQ-ORACLE-061
    // Sources: MATH-UO-64 (any input outside the bounds is a malformed module read, never a revert)
    function testFuzz_TEST_036_lpPriceMalformedNeverReverts(
        uint256 seed,
        uint8 na,
        uint8 nv,
        uint8 nd
    ) public view {
        (na, nv, nd) = (uint8(bound(na, 0, 10)), uint8(bound(nv, 0, 10)), uint8(bound(nd, 0, 10)));
        uint256[] memory a = new uint256[](na);
        uint256[] memory v = new uint256[](nv);
        uint8[] memory d = new uint8[](nd);
        bool inBounds = na == nv && nv == nd && na >= 2 && na <= MAX_TOKENS;
        for (uint256 i = 0; i < 10; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            if (i < na) a[i] = h % 4 == 0 ? 2 ** 128 + (h >> 8) % 1000 : (h >> 8) % 2 ** 128;
            if (i < nv) v[i] = h % 5 == 0 ? (h % 2 == 0 ? 0 : MAX_ROUTE + 1) : 1 + (h >> 16) % MAX_ROUTE;
            if (i < nd) d[i] = uint8(h % 7 == 0 ? 78 + (h >> 24) % 100 : (h >> 24) % 19);
            if (i < na && i < nv && i < nd) {
                inBounds = inBounds && a[i] < 2 ** 128 && v[i] >= 1 && v[i] <= MAX_ROUTE && d[i] <= 77;
            }
        }
        (bool valid, uint256 price8) = m.lpPrice(a, v, d);
        assertEq(valid, inBounds, "valid exactly inside the bounds");
        if (valid) assertGe(price8, 1, "valid: at least 1");
        else assertEq(price8, 0, "invalid: 0");
    }

    // ─── SPEC-ORC-011 ───

    // TEST-251 verifies: SPEC-ORC-011, REQ-ORACLE-009, REQ-ORACLE-015
    // Sources: MATH-UO-53a, MATH-UO-53b, MATH-UO-53c, MATH-UO-62a
    function testFuzz_TEST_251_usdBandIsTheFixedPointTest(
        uint256 seed,
        uint256 n,
        uint256 low,
        uint256 high
    ) public view {
        n = bound(n, 2, MAX_TOKENS);
        (, uint256[] memory q,) = _vectors(seed, n);
        uint256[] memory v = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            v[i] = q[i] > 1e8 ? 1e8 : q[i];
        }
        low = bound(low, 0, MAX_ROUTE);
        high = bound(high, low, MAX_ROUTE);
        uint256 pq = q[0];
        uint256 pv = v[0];
        for (uint256 i = 1; i < n; ++i) {
            pq = pq * q[i] / 1e8;
            pv = pv * v[i] / 1e8;
        }
        assertLt(pq, SAT, "valid quotes never saturate");
        assertEq(m.fixedPointProduct(q), pq, "left-to-right fixed-point product");
        uint256 pl = m.fixedPointPower(low, n);
        (bool valid, bool inBand) = m.inUsdBand(q, v, low, high);
        assertTrue(valid, "valid input");
        assertEq(inBand, pl <= pq && pv <= m.fixedPointPower(high, n), "lower on uncapped, upper on capped");
        (, bool sentinel) = m.inUsdBand(q, v, 0, SAT);
        assertTrue(sentinel, "sentinels always pass");
    }

    // TEST-251 verifies: SPEC-ORC-011, REQ-ORACLE-042
    // Sources: MATH-UO-61a … MATH-UO-61e (usdLevel = max{L : L^(x)n <= (x)q} and its agreement with the band)
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_TEST_251_usdLevelIsTheLargestPassingLevel(
        uint256 seed,
        uint256 n,
        uint256 low
    ) public view {
        n = bound(n, 2, MAX_TOKENS);
        uint256[] memory q = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            // Stables near $1 in most runs, anything in the bounds otherwise.
            q[i] = h % 4 == 0 ? 1 + (h >> 8) % MAX_ROUTE : 80_000_000 + (h >> 8) % 40_000_001;
        }
        uint256 product = m.fixedPointProduct(q);
        uint256 level = m.usdLevel(q);
        assertLe(m.fixedPointPower(level, n), product, "the level passes");
        assertGt(m.fixedPointPower(level + 1, n), product, "one more fails");
        low = bound(low, 0, 2 * MAX_ROUTE);
        (, bool inBand) = m.inUsdBand(q, q, low, SAT);
        assertEq(low <= level, inBand, "usdBandLow <= usdLevel exactly when the lower band test passes");
    }

    // TEST-251 verifies: SPEC-ORC-011
    // Sources: MATH-UO-61b, MATH-UO-61c, MATH-UO-62b (monotone and sticky with saturation)
    function testFuzz_TEST_251_fixedPointPowerMonotoneAndSticky(
        uint256 b1,
        uint256 b2,
        uint256 n
    ) public view {
        n = bound(n, 1, MAX_TOKENS);
        if (b1 > b2) (b1, b2) = (b2, b1);
        assertLe(m.fixedPointPower(b1, n), m.fixedPointPower(b2, n), "non-decreasing in the base");
        uint256[] memory xs = new uint256[](3);
        (xs[0], xs[1], xs[2]) = (SAT, b1, b2);
        assertEq(m.fixedPointProduct(xs), SAT, "a saturated factor stays saturated");
    }

    // ─── SPEC-ORC-012, SPEC-ORC-015 ───

    // TEST-038 verifies: SPEC-ORC-012, REQ-ORACLE-021, REQ-ORACLE-066
    // Sources: MATH-UO-48c, MATH-UO-66a
    function testFuzz_TEST_038_servedTimestampOldestOrAccepted(
        uint64[8] memory raw,
        uint256 n,
        bool failed,
        uint64 accepted
    ) public view {
        n = bound(n, 0, MAX_TOKENS);
        uint64[] memory t = new uint64[](n);
        for (uint256 i = 0; i < n; ++i) {
            t[i] = raw[i];
        }
        uint64 s = m.servedTimestamp(t, failed, accepted);
        if (failed) {
            assertEq(s, accepted, "failed: accepted timestamp");
            return;
        }
        if (n == 0) {
            assertEq(s, 0, "no timestamp: 0");
            return;
        }
        bool hit;
        for (uint256 i = 0; i < n; ++i) {
            assertLe(s, t[i], "never newer than an input");
            hit = hit || s == t[i];
        }
        assertTrue(hit, "one of the inputs");
    }

    // TEST-250 verifies: SPEC-ORC-015, SPEC-ORC-019, REQ-ORACLE-043, REQ-ORACLE-090
    // Sources: MATH-UO-46a, MATH-UO-46b, MATH-UO-50a
    function testFuzz_TEST_250_ageLimitsMatchEveryLegsOwnLimit(
        uint64[4] memory updatedAt,
        uint32[4] memory borrowAge,
        uint32[4] memory liquidationAge,
        bool[4] memory alternate,
        uint256 n,
        uint256 elapsed
    ) public view {
        n = bound(n, 1, 4);
        LPPriceMath.LegAge[] memory legs = new LPPriceMath.LegAge[](n);
        uint256 newest;
        for (uint256 i = 0; i < n; ++i) {
            legs[i] = LPPriceMath.LegAge(updatedAt[i], borrowAge[i], liquidationAge[i], alternate[i]);
            if (updatedAt[i] > newest) newest = updatedAt[i];
        }
        _checkAgeLimits(legs, newest + bound(elapsed, 0, 2 ** 33));
        (uint32 b, uint32 l) = m.ageLimits(legs, true);
        assertEq(uint256(b) + l, 0, "failed: 0");
    }

    /// @dev The consumer test `now - servedUpdatedAt <= maxAge` holds iff every leg is within its own limit.
    function _checkAgeLimits(
        LPPriceMath.LegAge[] memory legs,
        uint256 nowTs
    ) internal view {
        (uint32 b, uint32 l) = m.ageLimits(legs, false);
        uint64[] memory t = new uint64[](legs.length);
        bool allBorrow = true;
        bool allLiquidation = true;
        for (uint256 i = 0; i < legs.length; ++i) {
            LPPriceMath.LegAge memory leg = legs[i];
            t[i] = leg.updatedAt;
            uint256 age = nowTs - leg.updatedAt;
            uint256 lim = leg.liquidationPriceMaxAge;
            if (leg.onAlternate && leg.borrowPriceMaxAge < lim) lim = leg.borrowPriceMaxAge;
            allBorrow = allBorrow && age <= leg.borrowPriceMaxAge;
            allLiquidation = allLiquidation && age <= lim;
        }
        uint256 served = m.servedTimestamp(t, false, 0);
        assertEq(nowTs - served <= b, allBorrow, "borrow limit");
        assertEq(nowTs - served <= l, allLiquidation, "liquidation limit");
    }

    // TEST-250 verifies: SPEC-ORC-019
    function testFuzz_TEST_250_feedMaxAgeIsHeartbeatPlusMargin(
        uint32 heartbeat,
        uint32 margin
    ) public view {
        assertEq(m.feedMaxAge(heartbeat, margin), uint256(heartbeat) + margin, "sum, no overflow");
    }

    // ─── SPEC-ORC-017, SPEC-ORC-018 ───

    // TEST-219 verifies: SPEC-ORC-017, REQ-ORACLE-020, REQ-ORACLE-060, REQ-ORACLE-086, INV-087
    // Sources: MATH-UO-42d, MATH-UO-52, MATH-UO-59a (lower is unconstrained: it may exceed fresh)
    function testFuzz_TEST_219_servedPriceBounds(
        uint8 stateRaw,
        bool disagreeing,
        uint256 fresh,
        uint256 lower,
        uint256 accepted
    ) public view {
        PriceState state = PriceState(bound(stateRaw, 0, 3));
        fresh = bound(fresh, 1, SAT);
        accepted = bound(accepted, 1, SAT);
        uint256 served = m.servedPrice(state, disagreeing, fresh, lower, accepted);
        assertGe(served, 1, "at least 1");
        if (state != PriceState.Live) assertLe(served, accepted, "at most A unless Live");
        if (state != PriceState.Cached && state != PriceState.Expired) assertLe(served, fresh, "at most fresh");
        if (state == PriceState.Expired) assertEq(served, 1, "Expired: 1");
    }

    // TEST-219 verifies: SPEC-ORC-017, SPEC-ORC-008, REQ-ORACLE-086, INV-087
    // Sources: MATH-UO-59c, SYM-191 (full-range USDC/USDT, d = 6: compositions of SPEC-ORC-009 and SPEC-ORC-006)
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_TEST_219_disagreementFromRealCompositions(
        uint256 v0,
        uint256 v1,
        uint256 cut0,
        uint256 cut1,
        uint256 accepted
    ) public view {
        v0 = bound(v0, 90_000_000, 110_000_000);
        v1 = bound(v1, 90_000_000, 110_000_000);
        uint256 w0 = v0 - bound(cut0, 0, 5_000_000);
        uint256 w1 = v1 - bound(cut1, 0, 5_000_000);
        accepted = bound(accepted, 1, 4e8);
        (, uint256 fresh) = m.lpPrice(_fullRange(v0, v1), _pair(v0, v1), _six());
        (, uint256 lower) = m.lpPrice(_fullRange(w0, w1), _pair(w0, w1), _six());
        uint256 served = m.servedPrice(PriceState.Drifting, true, fresh, lower, accepted);
        assertLe(served, fresh, "never above the fresh price, even when the floored lower price is");
        assertLe(served, accepted, "never above A");
        assertLe(served, lower, "never above the lower-route price");
    }

    // TEST-219 verifies: SPEC-ORC-018, REQ-ORACLE-093, INV-087
    // Sources: MATH-UO-43a, MATH-UO-43b, MATH-UO-43c, MATH-UO-65
    function testFuzz_TEST_219_debtServedPriceBounds(
        uint8 stateRaw,
        uint256 q,
        uint256 p,
        uint256 b,
        uint256 accepted,
        uint256 rise
    ) public view {
        PriceState state = PriceState(bound(stateRaw, 0, 3));
        q = bound(q, 1, MAX_ROUTE);
        p = bound(p, 1, MAX_ROUTE);
        b = bound(b, 1, MAX_ROUTE);
        accepted = bound(accepted, 1, MAX_ROUTE);
        rise = bound(rise, 0, 20_000);
        uint256 served = m.debtServedPrice(state, q, p, b, accepted, rise);
        uint256 effective = rise < 100 ? 100 : rise;
        assertGe(served, 1, "at least 1");
        if (state != PriceState.Live) assertGe(served, accepted, "at least A unless Live");
        if (state == PriceState.Live) assertEq(served, q, "Live: q");
        if (state == PriceState.Cached) assertEq(served, accepted, "Cached: A");
        if (state == PriceState.Expired) {
            assertGt(served, accepted, "the stress rise is strictly above A");
            assertGe(served * 1e4, accepted * (1e4 + effective), "rounds up");
            assertLt((served - 1) * 1e4, accepted * (1e4 + effective), "by less than one unit");
            if (rise <= 5000) assertLe(served * 2, accepted * 3 + 2, "at most 1.5 A + 1 inside the bound");
        }
        if (state == PriceState.Drifting) assertEq(served, Math.max(Math.max(p, b), accepted), "max(p, b, A)");
    }

    // ─── SPEC-ORC-021, SPEC-ORC-022, SPEC-ORC-023 ───

    // TEST-275 verifies: SPEC-ORC-021, REQ-ORACLE-099
    // Sources: MATH-UO-55a, MATH-UO-55b, MATH-UO-55c, MATH-UO-55d
    function testFuzz_TEST_275_sequencerStatusPartitions(
        bool hasFeed,
        bool readOk,
        int256 answer,
        uint256 startedAt,
        uint256 nowTs,
        uint32 grace
    ) public view {
        answer = bound(answer, -2, 3);
        nowTs = bound(nowTs, 0, type(uint64).max);
        startedAt = bound(startedAt, 0, type(uint64).max);
        (bool up, bool down, bool unknown, bool inGrace, bool ready) =
            m.sequencerStatus(hasFeed, readOk, answer, startedAt, nowTs, grace);
        if (!hasFeed) {
            assertTrue(ready && !up && !down && !unknown && !inGrace, "no feed: ready");
            return;
        }
        assertEq(_count(up, down, unknown), 1, "exactly one of up, down, unknown");
        assertEq(up, inGrace != ready, "up is grace or ready, never both");
        if (ready) assertGe(nowTs, startedAt + grace, "ready only after the grace period");
        if (down) assertTrue(readOk && answer == 1, "down only on answer 1");
        if (!readOk) assertTrue(unknown, "an unreadable feed is unknown");
    }

    // TEST-139 verifies: SPEC-ORC-022, REQ-ORACLE-055
    // Sources: MATH-UO-56a, MATH-UO-66a
    function testFuzz_TEST_139_minObservationsCoverTheWindow(
        uint256 window,
        uint256 blockTime
    ) public view {
        window = bound(window, 0, type(uint64).max);
        blockTime = bound(blockTime, 0, 3600);
        uint256 k = m.minObservations(window, blockTime);
        if (blockTime == 0) {
            assertEq(k, SAT, "zero block time: impossible requirement");
            return;
        }
        assertGe((k - 1) * blockTime, window, "k observations one per block span the window");
        if (k >= 2) assertLt((k - 2) * blockTime, window, "the smallest such k");
    }

    // TEST-042 verifies: SPEC-ORC-023, REQ-ORACLE-039, REQ-ORACLE-102, REQ-ORACLE-038
    // Sources: MATH-UO-57a, MATH-UO-66b
    function testFuzz_TEST_042_gasGuardForwardsTheFullGas(
        uint256 callGas,
        uint256 worstCase
    ) public view {
        callGas = bound(callGas, 0, 30_000_000);
        worstCase = bound(worstCase, 0, 30_000_000);
        uint256 required = m.gasForCall(callGas);
        uint256 atCall = required - LPPriceMath.POST_CALL_GAS;
        assertGe(atCall - atCall / 64, callGas, "the EVM forwards all of G");
        if (atCall > 0) assertLt((atCall - 1) * 63, 64 * callGas, "the smallest such bound");
        assertEq(m.pokeMinGasFloor(worstCase, callGas), worstCase + required, "floor = W + the pre-call bound");
    }

    // ─── Helpers ───

    /// @dev Amounts below 2^128, prices in [1, MAX_ROUTE_ANSWER], decimals in [0, 18], from one seed.
    function _vectors(
        uint256 seed,
        uint256 n
    ) internal pure returns (uint256[] memory a, uint256[] memory v, uint8[] memory d) {
        a = new uint256[](n);
        v = new uint256[](n);
        d = new uint8[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            a[i] = (h & type(uint128).max) >> (h >> 248 & 127);
            v[i] = 1 + (h >> 128 & type(uint64).max) % MAX_ROUTE;
            d[i] = uint8((h >> 200) % 19);
        }
    }

    /// @dev Full-range composition of 10^6 units of a (6, 6)-decimal pool at prices (x0, x1): `SPEC-ORC-009` sqrt price,
    /// clamped to the full range, and the `SPEC-ORC-006` amounts, every step rounding down.
    function _fullRange(
        uint256 x0,
        uint256 x1
    ) internal pure returns (uint256[] memory amounts) {
        uint256 num = x0 * 1e6;
        uint256 den = x1 * 1e6;
        uint256 s = num >= den << 64 ? MAX_SQRT_RATIO - 1 : Math.sqrt(Math.mulDiv(num, 1 << 192, den));
        if (s < MIN_SQRT_RATIO) s = MIN_SQRT_RATIO;
        uint256 u = 1e6;
        amounts = new uint256[](2);
        amounts[0] = Math.mulDiv(u << 96, MAX_SQRT_RATIO - s, MAX_SQRT_RATIO) / s;
        amounts[1] = Math.mulDiv(u, s - MIN_SQRT_RATIO, 1 << 96);
    }

    function _pair(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        (out[0], out[1]) = (x, y);
    }

    function _six() internal pure returns (uint8[] memory out) {
        out = new uint8[](2);
        (out[0], out[1]) = (6, 6);
    }

    function _count(
        bool a,
        bool b,
        bool c
    ) internal pure returns (uint256) {
        return (a ? 1 : 0) + (b ? 1 : 0) + (c ? 1 : 0);
    }
}
