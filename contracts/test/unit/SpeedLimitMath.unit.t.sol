// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpeedLimitMath} from "../../src/policy/risk-module/SpeedLimitMath.sol";
import {SpeedView} from "../../src/policy/risk-module/types/SpeedView.sol";
import {SpeedWindow} from "../../src/policy/risk-module/types/SpeedWindow.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";

/// @title SpeedLimitMathUnitTest
/// @notice The speed-window arithmetic of 2.7 SPEC-CAP-011 to SPEC-CAP-013 on the worked examples: rollover, fit, the
/// window-start base, the clamped limit on it, the net credit of a repay or withdrawal, next-capacity time and the USD
/// charge.
contract SpeedLimitMathUnitTest is AvanaTest {
    uint256 internal constant TAU = 21_600;
    uint256 internal constant E8 = 1e8;

    function _w(
        uint64 start,
        uint96 prev,
        uint96 curr
    ) internal pure returns (SpeedWindow memory w) {
        w = SpeedWindow(start, prev, curr, 0, false);
    }

    function _eq(
        SpeedWindow memory a,
        uint64 start,
        uint96 prev,
        uint96 curr,
        string memory why
    ) internal pure {
        assertEq(a.start, start, why);
        assertEq(a.prev, prev, why);
        assertEq(a.curr, curr, why);
    }

    function _eq(
        SpeedWindow memory a,
        uint64 start,
        uint96 prev,
        uint96 curr
    ) internal pure {
        assertEq(a.start, start, "start");
        assertEq(a.prev, prev, "prev");
        assertEq(a.curr, curr, "curr");
    }

    // ------------------------------------------------------------------------------------------------- rollover

    // TEST-320 verifies: SPEC-CAP-011
    function test_TEST_320_rollKeepsTheBucketBeforeTau() public pure {
        _eq(SpeedLimitMath.roll(_w(1000, 7, 9), TAU, 1000), 1000, 7, 9);
        _eq(SpeedLimitMath.roll(_w(1000, 7, 9), TAU, 1000 + TAU - 1), 1000, 7, 9);
    }

    // TEST-320 verifies: SPEC-CAP-011
    function test_TEST_320_rollMovesCurrToPrevFromTau() public pure {
        _eq(SpeedLimitMath.roll(_w(1000, 7, 9), TAU, 1000 + TAU), uint64(1000 + TAU), 9, 0);
        _eq(SpeedLimitMath.roll(_w(1000, 7, 9), TAU, 1000 + 2 * TAU - 1), uint64(1000 + TAU), 9, 0);
    }

    // TEST-320 verifies: SPEC-CAP-011
    function test_TEST_320_rollEmptiesFromTwoTau() public pure {
        _eq(SpeedLimitMath.roll(_w(1000, 7, 9), TAU, 1000 + 2 * TAU), uint64(1000 + 2 * TAU), 0, 0);
        _eq(SpeedLimitMath.roll(_w(1000, 7, 9), TAU, 10_000_000), 10_000_000, 0, 0);
    }

    // TEST-320 verifies: SPEC-CAP-011, REQ-RISK-096
    function test_TEST_320_neverWrittenWindowRollsEmpty() public pure {
        _eq(SpeedLimitMath.roll(_w(0, 0, 0), TAU, 1_762_650_000), 1_762_650_000, 0, 0);
        // A scope with no window (never written) is empty at every check.
        _eq(SpeedLimitMath.roll(_w(500, 3, 4), 0, 500), 500, 0, 0);
    }

    // ------------------------------------------------------------------------------------------------- fit and add

    // TEST-320 verifies: SPEC-CAP-011
    function test_TEST_320_fitIsInclusiveAtL() public pure {
        SpeedWindow memory r = _w(0, 400, 200);
        assertTrue(SpeedLimitMath.fits(r, 1000, 400), "prev + curr + x == L passes");
        assertFalse(SpeedLimitMath.fits(r, 1000, 401), "one unit more fails");
        assertTrue(SpeedLimitMath.fits(r, 600, 0), "zero fits a full window");
        assertFalse(SpeedLimitMath.fits(r, 599, 0), "nothing fits an overfull window");
        assertFalse(SpeedLimitMath.fits(r, 1000, type(uint256).max), "no overflow on a huge charge");
    }

    // TEST-320 verifies: SPEC-CAP-011
    function test_TEST_320_addChargesTheCurrentBucket() public pure {
        SpeedWindow memory a = SpeedLimitMath.add(_w(5, 400, 200), 300, 7000);
        _eq(a, 5, 400, 500);
        assertEq(a.base, 7000, "the window-start base is recorded");
        assertTrue(a.opened, "and the bucket marked opened");
        assertEq(SpeedLimitMath.add(_w(5, 0, 0), 1, type(uint256).max).base, type(uint248).max, "a huge base caps");
    }

    // ------------------------------------------------------------------------------------------------- limit

    // TEST-320 verifies: SPEC-CAP-012
    function test_TEST_320_limitWorkedExample() public pure {
        // Window-start base $3,400,000, 2,500 bps within $250,000 .. $2,500,000.
        uint256 lim = SpeedLimitMath.limit(2500, 250_000 * E8, 2_500_000 * E8, 3_400_000 * E8);
        assertEq(lim, 850_000 * E8, "L = $850,000");
        assertEq(lim - 600_000 * E8, 250_000 * E8, "available $250,000 after $600,000");
    }

    // TEST-320 verifies: SPEC-CAP-012
    function test_TEST_320_limitClampsToMinAndMax() public pure {
        assertEq(SpeedLimitMath.limit(2500, 250_000 * E8, 2_500_000 * E8, 0), 250_000 * E8, "new market: L_min");
        assertEq(
            SpeedLimitMath.limit(2500, 250_000 * E8, 2_500_000 * E8, 10_000_000 * E8),
            2_500_000 * E8,
            "from $10,000,000 of base: L_max"
        );
        assertEq(SpeedLimitMath.limit(2500, 250_000 * E8, 2_500_000 * E8, 20_000_000 * E8), 2_500_000 * E8);
        assertEq(SpeedLimitMath.limit(2500, 0, type(uint96).max, 3), 0, "floor of 3 x 0.25");
        assertEq(SpeedLimitMath.limit(10_000, 0, type(uint96).max, type(uint256).max), type(uint96).max);
    }

    // TEST-320 verifies: SPEC-CAP-012
    function test_TEST_320_pledgeWorkedExample() public pure {
        uint256 lim = SpeedLimitMath.limit(2500, 1_000_000 * E8, 10_000_000 * E8, 5_000_000 * E8);
        assertEq(lim, 1_250_000 * E8, "P = $1,250,000");
    }

    // ------------------------------------------------------------------------------------------------- window-start base

    // TEST-320 verifies: SPEC-CAP-012
    function test_TEST_320_windowBaseIsFixedWhileTheBucketIsOpen() public pure {
        // A charge opened the bucket at 1,000 with base $3,400,000: the live base no longer moves the limit.
        SpeedWindow memory stored = SpeedLimitMath.add(_w(1000, 0, 0), 600_000 * E8, 3_400_000 * E8);
        SpeedWindow memory r = SpeedLimitMath.roll(stored, TAU, 1000 + 100);
        assertEq(SpeedLimitMath.windowBase(stored, r, 4_000_000 * E8), 3_400_000 * E8, "a borrow does not raise it");
        assertEq(SpeedLimitMath.windowBase(stored, r, 3_400_000 * E8), 3_400_000 * E8, "a repay does not lower it");
        assertEq(SpeedLimitMath.windowBase(stored, r, 0), 3_400_000 * E8, "nor does a full repay");
    }

    // TEST-320 verifies: SPEC-CAP-012
    function test_TEST_320_windowBaseOfANewBucketIsTheLiveBaseLessPrev() public pure {
        SpeedWindow memory stored = SpeedLimitMath.add(_w(1000, 0, 0), 600_000 * E8, 3_400_000 * E8);
        // One rollover: the charges move to prev and the next charge opens a new bucket.
        SpeedWindow memory r = SpeedLimitMath.roll(stored, TAU, 1000 + TAU);
        assertEq(r.prev, 600_000 * E8);
        assertFalse(r.opened, "the rolled bucket is not opened yet");
        assertEq(SpeedLimitMath.windowBase(stored, r, 4_000_000 * E8), 3_400_000 * E8, "live base less prev");
        assertEq(SpeedLimitMath.windowBase(stored, r, 500_000 * E8), 0, "saturates at 0");
        // A window never written uses the live base.
        SpeedWindow memory empty = _w(0, 0, 0);
        assertEq(SpeedLimitMath.windowBase(empty, SpeedLimitMath.roll(empty, TAU, 50), 7), 7);
        assertEq(SpeedLimitMath.windowBase(empty, SpeedLimitMath.roll(empty, TAU, 1_762_650_000), 7), 7);
    }

    // ------------------------------------------------------------------------------------------------- credit

    // TEST-320 verifies: SPEC-CAP-011, REQ-RISK-092
    function test_TEST_320_creditTakesFromCurrThenPrevNeverBelowZero() public pure {
        SpeedWindow memory w = _w(1000, 40, 100);
        _eq(SpeedLimitMath.credit(w, TAU, 1000 + 3600, 30), 1000, 40, 70, "from curr");
        _eq(SpeedLimitMath.credit(w, TAU, 1000 + 3600, 120), 1000, 20, 0, "curr, then prev");
        _eq(SpeedLimitMath.credit(w, TAU, 1000 + 3600, 1_000_000), 1000, 0, 0, "never below zero");
        _eq(SpeedLimitMath.credit(w, TAU, 1000 + 3600, 0), 1000, 40, 100, "nothing to credit");
    }

    // TEST-320 verifies: SPEC-CAP-011
    function test_TEST_320_creditAfterOneRolloverTakesFromTheRolledPrev() public pure {
        // From start + tau the stored curr is the rolled prev; the stored prev no longer counts.
        SpeedWindow memory w = _w(1000, 40, 100);
        SpeedWindow memory c = SpeedLimitMath.credit(w, TAU, 1000 + TAU + 5, 120);
        _eq(c, 1000, 40, 0, "only the counting bucket");
        assertEq(SpeedLimitMath.used(SpeedLimitMath.roll(c, TAU, 1000 + TAU + 5)), 0, "the window is empty");
        _eq(SpeedLimitMath.credit(w, TAU, 1000 + 2 * TAU, 120), 1000, 40, 100, "nothing counts from start + 2 tau");
        _eq(SpeedLimitMath.credit(w, 0, 1000, 120), 1000, 40, 100, "a scope with no window");
    }

    // TEST-320 verifies: SPEC-CAP-011, SPEC-CAP-012
    function test_TEST_320_creditKeepsTheFrameAndTheBase() public pure {
        SpeedWindow memory w = SpeedLimitMath.add(_w(1000, 0, 0), 500, 9000);
        SpeedWindow memory c = SpeedLimitMath.credit(w, TAU, 1000 + 10, 500);
        assertEq(c.base, 9000);
        assertTrue(c.opened);
        assertEq(SpeedLimitMath.windowBase(c, SpeedLimitMath.roll(c, TAU, 1000 + 10), 1), 9000);
    }

    // TEST-320 verifies: SPEC-CAP-011, SPEC-CAP-012, ATTACK-206
    function test_TEST_320_borrowRepayCyclesNeverFillTheWindow() public pure {
        // L = $1,000,000 on a $4,000,000 base; ten $100,000 borrow and repay cycles leave the window empty.
        uint256 t = 1_762_650_000;
        SpeedWindow memory w;
        for (uint256 i = 0; i < 10; ++i) {
            SpeedWindow memory r = SpeedLimitMath.roll(w, TAU, t);
            uint256 base = SpeedLimitMath.windowBase(w, r, 4_000_000 * E8);
            uint256 lim = SpeedLimitMath.limit(2500, 250_000 * E8, 2_500_000 * E8, base);
            assertEq(lim, 1_000_000 * E8, "the limit of the window-start base");
            assertTrue(SpeedLimitMath.fits(r, lim, 100_000 * E8));
            w = SpeedLimitMath.add(r, 100_000 * E8, base);
            w = SpeedLimitMath.credit(w, TAU, t, 100_000 * E8);
            t += 60;
        }
        assertEq(SpeedLimitMath.used(SpeedLimitMath.roll(w, TAU, t)), 0, "net zero");
    }

    // ------------------------------------------------------------------------------------------------- moreAt

    // TEST-320 verifies: SPEC-CAP-011, REQ-RISK-097
    function test_TEST_320_moreAtPrevThenCurrThenNone() public pure {
        (uint64 at, uint256 amount) = SpeedLimitMath.moreAt(_w(21_600, 850_000, 10), TAU);
        assertEq(at, 43_200);
        assertEq(amount, 850_000);
        (at, amount) = SpeedLimitMath.moreAt(_w(21_600, 0, 10), TAU);
        assertEq(at, 64_800);
        assertEq(amount, 10);
        (at, amount) = SpeedLimitMath.moreAt(_w(21_600, 0, 0), TAU);
        assertEq(at, 0);
        assertEq(amount, 0);
    }

    // TEST-320 verifies: SPEC-CAP-011, REQ-RISK-097
    function test_TEST_320_timelineWorkedExample() public pure {
        // L = $1,000,000, tau 6 h: $500,000 at t = 0 and $350,000 at t = 18,000; at t = 25,000 $150,000 is available
        // and the full limit from t = 43,200.
        SpeedWindow memory w = SpeedLimitMath.add(SpeedLimitMath.roll(_w(0, 0, 0), TAU, 0), 500_000, 0);
        w = SpeedLimitMath.add(SpeedLimitMath.roll(w, TAU, 18_000), 350_000, 0);
        _eq(w, 0, 0, 850_000);
        SpeedWindow memory r = SpeedLimitMath.roll(w, TAU, 25_000);
        _eq(r, 21_600, 850_000, 0);
        SpeedView memory v = SpeedLimitMath.viewOf(r, TAU, 1_000_000);
        assertEq(v.limit, 1_000_000);
        assertEq(v.used, 850_000);
        assertEq(v.available, 150_000);
        assertEq(v.moreAt, 43_200);
        assertEq(v.moreAmount, 850_000);
        assertFalse(v.unavailable);
        assertEq(SpeedLimitMath.used(SpeedLimitMath.roll(w, TAU, 43_200)), 0, "full limit from 43,200");
    }

    // TEST-320 verifies: REQ-RISK-097
    function test_TEST_320_viewOfAnOverfullWindowHasNoRoom() public pure {
        SpeedView memory v = SpeedLimitMath.viewOf(_w(0, 700, 500), TAU, 1000);
        assertEq(v.used, 1200);
        assertEq(v.available, 0);
    }

    // ------------------------------------------------------------------------------------------------- USD charge

    // TEST-320 verifies: SPEC-CAP-013
    function test_TEST_320_usdChargeRoundsUp() public pure {
        assertEq(SpeedLimitMath.usdOf(300_000e6, 99_990_000, 6), 29_997_000_000_000, "300,000 USDC at $0.9999");
        assertEq(SpeedLimitMath.usdOf(1, 99_990_000, 18), 1, "a dust charge rounds up to one unit");
        assertEq(SpeedLimitMath.usdOf(0, 99_990_000, 18), 0);
        assertEq(SpeedLimitMath.usdOf(3, 1, 0), 3);
    }

    // TEST-320 verifies: SPEC-CAP-011
    function test_TEST_320_rollAndAddReturnNewWindows() public pure {
        SpeedWindow memory w = _w(1000, 7, 9);
        SpeedWindow memory r = SpeedLimitMath.roll(w, TAU, 1000);
        SpeedWindow memory a = SpeedLimitMath.add(r, 5, 0);
        _eq(a, 1000, 7, 14);
        _eq(r, 1000, 7, 9, "the rolled window is left unchanged by add");
        r.curr = 100;
        _eq(w, 1000, 7, 9, "the stored copy is left unchanged by a write to the rolled window");
    }
}
