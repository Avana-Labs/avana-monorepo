// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {ClPriceMathHarness} from "../utils/harness/ClPriceMathHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice ClPriceMath: the worked examples of 2.10 and 2.20, tick bounds, signed alignment, the per-tick bound, the
/// mean tick and harmonic liquidity, and fuzzed bounds of the composition against the exact value.
contract ClPriceMathUnitTest is AvanaTest {
    ClPriceMathHarness internal m;

    function setUp() public {
        m = new ClPriceMathHarness();
    }

    function _comp(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1,
        int24 lower,
        int24 upper,
        uint256 units
    ) internal view returns (uint256 a0, uint256 a1) {
        (uint160 s,) = m.oracleSqrtPrice(p0, p1, d0, d1);
        uint160 sa = m.sqrtRatioAtTick(lower);
        uint160 sb = m.sqrtRatioAtTick(upper);
        return m.amountsForLiquidity(m.clamp(s, sa, sb), sa, sb, units);
    }

    // TEST-279 verifies: SPEC-ORC-006, SPEC-AMM-V3-001, SPEC-AMM-CORE-001, REQ-AMM-V3-005, REQ-ORACLE-012
    // Sources: 2.10 SPEC-ORC-006 and SPEC-ORC-008 examples, 2.19 SPEC-AMM-CORE-001 example, 2.20 SPEC-AMM-V3-001
    function test_TEST_279_workedExamplesOfTheClampedComposition() public view {
        (uint256 a0, uint256 a1) = _comp(1e8, 1e8, 6, 6, -10, 10, 1e12);
        assertEq(a0, 499_850_034, "[-10,10] token0 floored");
        assertEq(a1, 499_850_034, "[-10,10] token1 floored");
        (a0, a1) = _comp(1e8, 1e8, 6, 6, -50, 50, 1e9);
        assertEq(a0, 2_496_752);
        assertEq(a1, 2_496_752);
        (a0, a1) = _comp(1e8, 64_000_000, 6, 6, -50, 50, 1e9);
        assertEq(a0, 0, "above the range: all token1");
        assertEq(a1, 4_999_755);
        (a0, a1) = _comp(1e8, 1e8, 6, 6, -887_220, 887_220, 5e9);
        assertEq(a0, 4_999_999_999);
        assertEq(a1, 4_999_999_999);
        (a0, a1) = _comp(1e8, 64_000_000, 6, 6, -887_220, 887_220, 5e9);
        assertEq(a0, 3_999_999_999);
        assertEq(a1, 6_249_999_999);
        (a0, a1) = _comp(99_987_000, 1e8, 6, 6, -10, 10, 1e10);
        assertEq(a0, 5_648_563, "SPEC-ORC-008 example");
        assertEq(a1, 4_348_479);
        (a0, a1) = _comp(1e8, 95_200_000, 6, 6, -100, 100, 1e9);
        assertEq(a0, 0, "SPEC-ORC-006 depeg example");
        assertEq(a1, 9_999_541);
    }

    // TEST-279 verifies: SPEC-ORC-009, REQ-ORACLE-012
    // Sources: 2.10 SPEC-ORC-009 example
    function test_TEST_279_oracleSqrtPriceExampleAndClamps() public view {
        (uint160 s, bool clamped) = m.oracleSqrtPrice(1e8, 1e8, 18, 6);
        assertEq(s, 79_228_162_514_264_337_593_543);
        assertFalse(clamped);
        (s, clamped) = m.oracleSqrtPrice(1e8, 1e8, 6, 6);
        assertEq(s, 2 ** 96);
        assertFalse(clamped);
        (s, clamped) = m.oracleSqrtPrice(1, 2 ** 100, 18, 0);
        assertEq(s, ClPriceMath.MIN_SQRT_RATIO, "below MIN_SQRT_RATIO");
        assertTrue(clamped);
    }

    // TEST-279 verifies: SPEC-ORC-009, REQ-ORACLE-012
    // Sources: 2.10 SPEC-ORC-009 example (b) (MATH-UO-11k); MATH-UO-11c, MATH-UO-11d, MATH-UO-11i (the branches join at
    // 2^64); review CL-01 (the root above 2^64 replaces the saturation at MAX_SQRT_RATIO - 1)
    function test_TEST_279_oracleSqrtPriceAboveTwoTo64IsTheRootNotASaturation() public view {
        (uint160 s, bool clamped) = m.oracleSqrtPrice(1e8, 5, 6, 18);
        assertEq(s, 354_319_114_228_591_420_592_203_432_319_359_385_600, "SPEC-ORC-009 example (b)");
        assertFalse(clamped);
        (s, clamped) = m.oracleSqrtPrice(1e12, 1, 6, 18);
        assertEq(s, 1e12 * 2 ** 96, "ratio 10^24: an exact root");
        assertFalse(clamped);
        // num = 2^64 * den: the upper branch gives exactly 2^128; one unit below, the lower branch stays under it.
        (s, clamped) = m.oracleSqrtPrice(2 ** 64, 1, 0, 0);
        assertEq(s, 2 ** 128);
        assertFalse(clamped);
        (uint160 below,) = m.oracleSqrtPrice(2 ** 64 - 1, 1, 0, 0);
        assertLt(below, 2 ** 128);
        assertGt(below, 2 ** 128 - 2 ** 64, "2^128 * sqrt(1 - 2^-64), about 2^128 - 2^63: no jump at the boundary");
        // Above the largest price: the root (2^128 - 1) * 2^32 reaches MAX_SQRT_RATIO, and num >= 2^128 * den.
        (s, clamped) = m.oracleSqrtPrice(2 ** 128 - 1, 1, 0, 0);
        assertEq(s, ClPriceMath.MAX_SQRT_RATIO - 1, "root at or above MAX_SQRT_RATIO");
        assertTrue(clamped);
        (s, clamped) = m.oracleSqrtPrice(2 ** 127, 1, 0, 18);
        assertEq(s, ClPriceMath.MAX_SQRT_RATIO - 1, "num >= 2^128 den");
        assertTrue(clamped);
    }

    // TEST-279 verifies: SPEC-ORC-009, REQ-ORACLE-012
    // Sources: MATH-UO-11f (never above the exact root, within 2^32 below it), MATH-UO-11g and MATH-UO-11h (monotone)
    function testFuzz_TEST_279_oracleSqrtPriceIsMonotoneAndNeverAboveTheRoot(
        uint256 p0,
        uint256 p1,
        uint256 step,
        uint8 d0,
        uint8 d1
    ) public view {
        p0 = bound(p0, 1, 1e12);
        p1 = bound(p1, 1, 1e12);
        step = bound(step, 1, 1e12);
        d0 = uint8(bound(d0, 0, 18));
        d1 = uint8(bound(d1, 0, 18));
        (uint160 s,) = m.oracleSqrtPrice(p0, p1, d0, d1);
        (uint160 sUp,) = m.oracleSqrtPrice(p0 + step, p1, d0, d1);
        assertLe(s, sUp, "a higher token0 price never lowers the root");
        uint256 num = p0 * 10 ** d1;
        uint256 den = p1 * 10 ** d0;
        if (num >= den << 64 && s < ClPriceMath.MAX_SQRT_RATIO - 1) {
            // Upper branch: s = r * 2^32 with r = isqrt(floor(num * 2^128 / den)); r^2 <= num * 2^128 / den < (r+1)^2.
            uint256 r = uint256(s) >> 32;
            assertEq(uint256(s), r << 32, "a multiple of 2^32");
            assertGe(r, 2 ** 96);
            assertLe(Math.mulDiv(r, r, 2 ** 128), num / den, "never above the exact root");
            assertGt(Math.mulDiv(r + 1, r + 1, 2 ** 128) + 1, num / den, "less than 2^32 below the exact root");
        } else if (num < den << 64) {
            assertLt(s, 2 ** 128, "lower branch stays below 2^128");
        }
    }

    // TEST-279 verifies: SPEC-ORC-006
    function test_TEST_279_tickBoundsMatchUniswap() public {
        assertEq(m.sqrtRatioAtTick(0), 2 ** 96);
        assertEq(m.sqrtRatioAtTick(ClPriceMath.MIN_TICK), ClPriceMath.MIN_SQRT_RATIO);
        assertEq(m.sqrtRatioAtTick(ClPriceMath.MAX_TICK), ClPriceMath.MAX_SQRT_RATIO);
        assertEq(m.tickAtSqrtRatio(ClPriceMath.MIN_SQRT_RATIO), ClPriceMath.MIN_TICK);
        assertEq(m.tickAtSqrtRatio(ClPriceMath.MAX_SQRT_RATIO - 1), ClPriceMath.MAX_TICK - 1);
        assertEq(m.tickAtSqrtRatio(2 ** 96), 0);
        vm.expectRevert(abi.encodeWithSelector(ClPriceMath.TickOutOfRange.selector, int24(887_273)));
        m.sqrtRatioAtTick(887_273);
        vm.expectRevert(abi.encodeWithSelector(ClPriceMath.SqrtRatioOutOfRange.selector, ClPriceMath.MAX_SQRT_RATIO));
        m.tickAtSqrtRatio(ClPriceMath.MAX_SQRT_RATIO);
    }

    // TEST-279 verifies: SPEC-BACK-001, REQ-ORACLE-105, REQ-AMM-CORE-003
    // Sources: 2.20 SPEC-BACK-001 example (AMM-A5c)
    function test_TEST_279_signedAlignmentAndUsableTicks() public view {
        assertFalse(m.isUsableRange(-516, 500, 10), "-516 % 10 == -6");
        assertTrue(m.isUsableRange(-520, 500, 10));
        assertTrue(m.isUsableRange(-887_220, 887_220, 60));
        assertFalse(m.isUsableRange(-887_280, 887_220, 60), "below the usable ticks");
        assertTrue(m.isUsableRange(-887_272, 887_272, 1));
        assertTrue(m.isUsableRange(-887_270, 887_270, 10));
        assertTrue(m.isUsableRange(-887_200, 887_200, 200));
        assertFalse(m.isUsableRange(-887_400, 887_200, 200));
        assertFalse(m.isUsableRange(50, 50, 10), "empty range");
        assertFalse(m.isUsableRange(60, 50, 10), "inverted");
        assertFalse(m.isUsableRange(-50, 50, 0), "zero spacing");
        assertFalse(m.isUsableRange(-50, 50, -10), "negative spacing");
    }

    // TEST-279 verifies: REQ-AMM-V3-007, SPEC-UNIT-006
    // Sources: 2.20 REQ-AMM-V3-007 (MATH-AMM-V3-PRICE-05)
    function test_TEST_279_maxLiquidityPerTickBelowTheCreditBound() public view {
        uint128 s1 = m.maxLiquidityPerTick(1);
        uint128 s200 = m.maxLiquidityPerTick(200);
        assertEq(s1, type(uint128).max / 1_774_545);
        assertApproxEqRel(s1, 1.92e32, 0.01e18);
        assertApproxEqRel(s200, 3.83e34, 0.01e18);
        assertLt(s200, 2 ** 120 - 1);
    }

    // TEST-279 verifies: REQ-AMM-SLIP-008, REQ-AMM-SLIP-014
    // Sources: 2.21 REQ-AMM-SLIP-008 (6,931 is the largest spacing whose per-tick bound fits 2^120 - 1); review CL-03
    function test_TEST_279_spacing6931IsTheLargestBelowTheCreditBound() public view {
        assertLe(m.maxLiquidityPerTick(6931), 2 ** 120 - 1);
        assertGt(m.maxLiquidityPerTick(6932), 2 ** 120 - 1);
        assertLe(m.maxLiquidityPerTick(2000), 2 ** 120 - 1);
    }

    // TEST-279 verifies: SPEC-ORC-010, REQ-AMM-V3-006
    function test_TEST_279_meanTickAndHarmonicLiquidity() public view {
        assertEq(m.meanTick(1800 * 7, 1800), 7);
        assertEq(m.meanTick(-1800 * 7, 1800), -7);
        assertEq(m.meanTick(-1800 * 7 - 1, 1800), -8, "rounds toward negative infinity");
        assertEq(m.meanTick(1800 * 7 + 1, 1800), 7);
        (uint256 l, bool ok) = m.harmonicMeanLiquidity(0, 1800);
        assertFalse(ok);
        assertEq(l, 0);
        (l, ok) = m.harmonicMeanLiquidity(1, 0);
        assertFalse(ok);
        // 1,800 s over a constant liquidity L: delta = 1,800 * 2^128 / L.
        uint256 liq = 1e18;
        uint160 delta = uint160((uint256(1800) << 128) / liq);
        (l, ok) = m.harmonicMeanLiquidity(delta, 1800);
        assertTrue(ok);
        assertApproxEqRel(l, liq, 1e9);
        (l, ok) = m.harmonicMeanLiquidity(1, 1800);
        assertEq(l, type(uint128).max, "saturates");
    }

    // TEST-217 verifies: SPEC-ORC-006, SPEC-ORC-007, SPEC-AMM-V3-001, REQ-AMM-V3-005, REQ-ORACLE-012
    // Sources: 5.1 TEST-217; AMM-A3f (floor then one raw unit keeps the quote at or below the exact value)
    function testFuzz_TEST_217_amountsNeverAboveTheExactHoldings(
        uint256 units,
        int24 tickSeed,
        int24 lowerSeed,
        uint16 widthSeed
    ) public view {
        units = bound(units, 1e4, 1e15);
        // Ticks within +-51,000 keep every product below 2^256 (square-root prices below 2^100).
        int24 lower = int24(bound(int256(lowerSeed), -50_000, 49_000));
        int24 upper = lower + int24(uint24(bound(uint256(widthSeed), 1, 1000)));
        int24 t = int24(bound(int256(tickSeed), int256(lower), int256(upper)));
        _checkBelowExact(t, lower, upper, units);
    }

    function _checkBelowExact(
        int24 t,
        int24 lower,
        int24 upper,
        uint256 units
    ) internal view {
        uint160 s = m.sqrtRatioAtTick(t);
        uint160 sa = m.sqrtRatioAtTick(lower);
        uint160 sb = m.sqrtRatioAtTick(upper);
        (uint256 a0, uint256 a1) = m.amountsForLiquidity(s, sa, sb, units);
        // Exact: a1 = L (s - sa) / 2^96 and a0 = L 2^96 (sb - s) / (s sb); the floors keep each at or below.
        assertLe(a1 * 2 ** 96, units * uint256(s - sa));
        assertLe(a0 * uint256(s) * uint256(sb), units * (uint256(sb - s) << 96));
    }

    // TEST-279 verifies: SPEC-ORC-006, SPEC-AMM-V3-001, INV-005
    // Sources: AMM-A4a (the clamped quote is all one token outside the range)
    function testFuzz_TEST_279_clampMakesTheOutOfRangeHoldingOneToken(
        uint256 p1Seed,
        uint256 units
    ) public view {
        units = bound(units, 1, 1e24);
        uint256 p1 = bound(p1Seed, 1, 1e12);
        (uint256 a0, uint256 a1) = _comp(1e8, p1, 6, 6, -100, 100, units);
        (uint160 s,) = m.oracleSqrtPrice(1e8, p1, 6, 6);
        if (s >= m.sqrtRatioAtTick(100)) assertEq(a0, 0, "above the range: no token0");
        if (s <= m.sqrtRatioAtTick(-100)) assertEq(a1, 0, "below the range: no token1");
    }

    // TEST-279 verifies: SPEC-ORC-010
    function testFuzz_TEST_279_tickAtSqrtRatioInvertsSqrtRatioAtTick(
        int24 tickSeed
    ) public view {
        int24 t = int24(bound(tickSeed, ClPriceMath.MIN_TICK, ClPriceMath.MAX_TICK - 1));
        uint160 s = m.sqrtRatioAtTick(t);
        assertEq(m.tickAtSqrtRatio(s), t, "exact tick");
        if (s > ClPriceMath.MIN_SQRT_RATIO) assertEq(m.tickAtSqrtRatio(s - 1), t - 1, "one below");
    }
}
