// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {LPPriceMath} from "../../src/oracle/lp-oracle/LPPriceMath.sol";
import {LPOracleCLMathHarness} from "../utils/harness/LPOracleCLMathHarness.sol";
import {Test} from "forge-std/Test.sol";

/// @title LPOracleCLFuzzTest
/// @notice Fuzz twins of the concentrated-liquidity module's Halmos checks and the module's arithmetic over the full
/// listing bounds: the oracle square-root price stays tickable, the mean tick rounds toward negative infinity, an
/// out-of-range composition is one-sided and matches Uniswap's amounts at the clamped edge, the composition is
/// monotone in units and refuses inputs outside the bounds instead of reverting, the TWAP quote of a tick round-trips
/// downward, and the shock check is the formula of `REQ-ORACLE-105`.
contract LPOracleCLFuzzTest is Test {
    LPOracleCLMathHarness internal h;

    function setUp() public {
        h = new LPOracleCLMathHarness();
    }

    function _range(
        int24 seed,
        uint24 width
    ) internal pure returns (int24 lower, int24 upper) {
        lower = int24(bound(int256(seed), ClPriceMath.MIN_TICK, ClPriceMath.MAX_TICK - 1));
        int256 maxWidth = int256(ClPriceMath.MAX_TICK) - lower;
        upper = int24(lower + int24(int256(bound(width, 1, uint256(maxWidth)))));
    }

    // TEST-305 verifies: SPEC-ORC-009, SPEC-ORC-010, REQ-ORACLE-104
    // Sources: PROP-025 fuzz twin
    function testFuzz_TEST_305_oracleSqrtIsTickable(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public {
        p0 = bound(p0, 1, LPPriceMath.MAX_ROUTE_ANSWER);
        p1 = bound(p1, 1, LPPriceMath.MAX_ROUTE_ANSWER);
        d0 = uint8(bound(d0, 0, 18));
        d1 = uint8(bound(d1, 0, 18));
        h.setMarket(d0, d1, ClPriceMath.MIN_TICK, ClPriceMath.MAX_TICK);
        uint160 s = h.oracleSqrt(p0, p1);
        assertGe(s, ClPriceMath.MIN_SQRT_RATIO);
        assertLt(s, ClPriceMath.MAX_SQRT_RATIO);
        ClPriceMath.tickAtSqrtRatio(s);
    }

    // TEST-305 verifies: SPEC-ORC-010
    // Sources: PROP-025 fuzz twin
    function testFuzz_TEST_305_meanTickRoundsDown(
        int56 c0,
        int56 c1,
        uint32 window
    ) public view {
        window = uint32(bound(window, 1, type(uint32).max));
        (bool ok, int24 tick) = h.meanOf(c0, c1, window);
        int256 delta;
        unchecked {
            delta = int256(int56(int256(c1) - int256(c0)));
        }
        int256 w = int256(uint256(window));
        int256 floorQ = delta >= 0 ? delta / w : -((-delta + w - 1) / w);
        bool inRange = floorQ >= ClPriceMath.MIN_TICK && floorQ <= ClPriceMath.MAX_TICK;
        assertEq(ok, inRange, "availability");
        if (ok) assertEq(int256(tick), floorQ, "floor");
    }

    // TEST-305 verifies: SPEC-ORC-006, SPEC-AMM-V3-001, REQ-ORACLE-104
    // Sources: PROP-025 fuzz twin, AMM-A4a, AMM-A4b
    function testFuzz_TEST_305_compositionIsUniswapAtTheClampedPrice(
        uint256 p0,
        uint256 p1,
        int24 seed,
        uint24 width,
        uint128 units
    ) public {
        p0 = bound(p0, 1, LPPriceMath.MAX_ROUTE_ANSWER);
        p1 = bound(p1, 1, LPPriceMath.MAX_ROUTE_ANSWER);
        (int24 lower, int24 upper) = _range(seed, width);
        h.setMarket(6, 18, lower, upper);
        _checkComposition(p0, p1, lower, upper, units);
    }

    function _checkComposition(
        uint256 p0,
        uint256 p1,
        int24 lower,
        int24 upper,
        uint128 units
    ) internal view {
        (bool ok, uint256 a0, uint256 a1) = h.composition(units, p0, p1);
        assertTrue(ok);
        uint160 s = h.oracleSqrt(p0, p1);
        _checkAmounts(a0, a1, s, lower, upper, units);
        _checkClampFlag(p0, p1, s, ClPriceMath.sqrtRatioAtTick(lower), ClPriceMath.sqrtRatioAtTick(upper));
    }

    function _checkAmounts(
        uint256 a0,
        uint256 a1,
        uint160 s,
        int24 lower,
        int24 upper,
        uint128 units
    ) internal pure {
        uint160 sa = ClPriceMath.sqrtRatioAtTick(lower);
        uint160 sb = ClPriceMath.sqrtRatioAtTick(upper);
        (uint256 e0, uint256 e1) = ClPriceMath.amountsForLiquidity(ClPriceMath.clamp(s, sa, sb), sa, sb, units);
        assertEq(a0, e0, "token0");
        assertEq(a1, e1, "token1");
        if (s <= sa) assertEq(a1, 0, "below: token0 only");
        if (s >= sb) assertEq(a0, 0, "above: token1 only");
    }

    function _checkClampFlag(
        uint256 p0,
        uint256 p1,
        uint160 s,
        uint160 sa,
        uint160 sb
    ) internal view {
        bool expected = s < sa || s > sb || ClPriceMath.oracleSqrtClamped(p0, p1, 6, 18);
        assertEq(h.clampedAt(p0, p1), expected, "clamp flag");
    }

    // TEST-305 verifies: SPEC-ORC-006, REQ-ORACLE-103, REQ-ORACLE-012
    function testFuzz_TEST_305_compositionMonotoneAndBounded(
        uint256 p0,
        uint256 p1,
        uint128 u,
        uint128 extra
    ) public {
        p0 = bound(p0, 1, LPPriceMath.MAX_ROUTE_ANSWER);
        p1 = bound(p1, 1, LPPriceMath.MAX_ROUTE_ANSWER);
        h.setMarket(18, 6, -887_270, 887_270);
        (, uint256 a0, uint256 a1) = h.composition(u, p0, p1);
        uint256 more = uint256(u) + extra;
        (bool ok, uint256 b0, uint256 b1) = h.composition(more, p0, p1);
        assertEq(ok, more < 2 ** 128, "units bound");
        if (ok) {
            assertGe(b0, a0, "token0 not monotone");
            assertGe(b1, a1, "token1 not monotone");
        }
        (ok,,) = h.composition(u, 0, p1);
        assertFalse(ok, "zero price accepted");
        (ok,,) = h.composition(u, p0, LPPriceMath.MAX_ROUTE_ANSWER + 1);
        assertFalse(ok, "price above the bound accepted");
    }

    // TEST-306 verifies: SPEC-ORC-020
    /// @dev `getQuoteAtTick` there and back never returns more than it started with.
    function testFuzz_TEST_306_quoteAtTickRoundTripsDown(
        int24 tick,
        uint64 amount,
        bool zeroForOne
    ) public view {
        tick = int24(bound(int256(tick), -400_000, 400_000));
        uint256 out = h.quoteAtTick(tick, amount, zeroForOne);
        uint256 back = h.quoteAtTick(tick, out, !zeroForOne);
        assertLe(back, amount, "round trip gained");
    }

    // TEST-306 verifies: REQ-ORACLE-105, SPEC-ORC-009
    function testFuzz_TEST_306_shockCheckIsTheFormula(
        uint256 q0,
        uint256 q1,
        uint8 d0,
        uint8 d1
    ) public {
        q0 = bound(q0, 1, LPPriceMath.MAX_ROUTE_ANSWER);
        q1 = bound(q1, 1, LPPriceMath.MAX_ROUTE_ANSWER);
        d0 = uint8(bound(d0, 0, 18));
        d1 = uint8(bound(d1, 0, 18));
        h.setMarket(d0, d1, -10, 10);
        bool expected = true;
        for (uint256 up = 0; up < 2; ++up) {
            uint256 p0 = up == 0 ? _raise(q0) : _lower(q0);
            uint256 p1 = up == 0 ? _lower(q1) : _raise(q1);
            if ((p0 * 10 ** d1) >> 128 >= p1 * 10 ** d0) expected = false;
        }
        assertEq(h.shockSqrtHolds(q0, q1), expected);
    }

    function _raise(
        uint256 q
    ) internal pure returns (uint256) {
        uint256 r = q * 100;
        return r > LPPriceMath.MAX_ROUTE_ANSWER ? LPPriceMath.MAX_ROUTE_ANSWER : r;
    }

    function _lower(
        uint256 q
    ) internal pure returns (uint256) {
        uint256 r = q / 100;
        return r == 0 ? 1 : r;
    }

    // TEST-306 verifies: SPEC-ORC-010
    function testFuzz_TEST_306_tickDistance(
        int24 a,
        int24 b
    ) public view {
        int256 diff = int256(a) - int256(b);
        assertEq(h.tickDistance(a, b), uint256(diff < 0 ? -diff : diff));
        assertEq(h.tickDistance(a, b), h.tickDistance(b, a));
    }
}
