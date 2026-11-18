// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpeedLimitMath} from "../../src/policy/risk-module/SpeedLimitMath.sol";
import {SpeedView, SpeedWindow} from "../../src/policy/risk-module/types/RiskModuleTypes.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SpeedLimitMathFuzzTest
/// @notice The net-flow window bound of SPEC-CAP-011 against a ghost log of every passing charge and applied credit:
/// however charges and credits are split in time and size, no interval of length τ holds more net charge (charges less
/// credits) than the limit of its last charge, no `2τ` more than twice the largest limit, a charge stops counting within
/// `2τ`, a credit never goes below zero, and the window-start base of SPEC-CAP-012 never moves inside an opened bucket.
contract SpeedLimitMathFuzzTest is AvanaTest {
    uint256 internal constant N = 24;

    struct Log {
        uint256[N] t;
        uint256[N] x;
        uint256[N] lim;
        uint256 n;
        // Applied credits, at their times.
        uint256[N] ct;
        uint256[N] cx;
        uint256 cn;
    }

    /// @dev Sum of logged charges at times in `[from, to]`.
    function _sum(
        Log memory g,
        uint256 from,
        uint256 to
    ) internal pure returns (uint256 s) {
        for (uint256 j = 0; j < g.n; ++j) {
            if (g.t[j] >= from && g.t[j] <= to) s += g.x[j];
        }
    }

    /// @dev Sum of logged applied credits at times in `[from, to]`.
    function _credits(
        Log memory g,
        uint256 from,
        uint256 to
    ) internal pure returns (uint256 s) {
        for (uint256 j = 0; j < g.cn; ++j) {
            if (g.ct[j] >= from && g.ct[j] <= to) s += g.cx[j];
        }
    }

    /// @dev Runs `N` attempts with times advancing by `gaps[i] % (tau + tau / 2)` and charges `xs[i] % (2L)`, each
    /// against its own limit `ls[i]`; when `credit` has bit `i` set, a credit of `cs[i]` follows at the same time.
    /// Returns the log of the charges that passed and of the credits as applied (the fall in `used`).
    function _run(
        uint32 tauSeed,
        uint64[N] memory gaps,
        uint96[N] memory xs,
        uint96[N] memory ls,
        uint96[N] memory cs,
        uint32 creditBits
    ) internal pure returns (Log memory g, uint256 tau) {
        tau = bound(tauSeed, 3600, 604_800);
        SpeedWindow memory w;
        uint256 t = 1_762_650_000;
        for (uint256 i = 0; i < N; ++i) {
            t += uint256(gaps[i]) % (tau + tau / 2);
            uint256 lim = bound(ls[i], 0, 1e30);
            uint256 x = lim == 0 ? 0 : uint256(xs[i]) % (2 * lim);
            SpeedWindow memory r = SpeedLimitMath.roll(w, tau, t);
            if (SpeedLimitMath.fits(r, lim, x)) {
                w = SpeedLimitMath.add(r, x, 0);
                (g.t[g.n], g.x[g.n], g.lim[g.n]) = (t, x, lim);
                ++g.n;
            }
            if ((creditBits >> i) & 1 == 0) continue;
            uint256 before = SpeedLimitMath.used(SpeedLimitMath.roll(w, tau, t));
            w = SpeedLimitMath.credit(w, tau, t, cs[i]);
            uint256 afterCredit = SpeedLimitMath.used(SpeedLimitMath.roll(w, tau, t));
            assertLe(afterCredit, before, "a credit never adds");
            assertEq(before - afterCredit, Math.min(before, cs[i]), "a credit takes min(x, used)");
            (g.ct[g.cn], g.cx[g.cn]) = (t, before - afterCredit);
            ++g.cn;
        }
    }

    // TEST-323 verifies: SPEC-CAP-011, REQ-RISK-092, REQ-RISK-093, ATTACK-205, INV-110
    // Sources: MATH-AR-85b, MATH-AR-85e
    function testFuzz_TEST_323_noTauIntervalExceedsItsLastLimit(
        uint32 tauSeed,
        uint64[N] memory gaps,
        uint96[N] memory xs,
        uint96[N] memory ls
    ) public pure {
        uint96[N] memory none;
        (Log memory g, uint256 tau) = _run(tauSeed, gaps, xs, ls, none, 0);
        for (uint256 i = 0; i < g.n; ++i) {
            // The last charge at this timestamp closes the interval.
            if (i + 1 < g.n && g.t[i + 1] == g.t[i]) continue;
            uint256 from = g.t[i] >= tau - 1 ? g.t[i] - (tau - 1) : 0;
            assertLe(_sum(g, from, g.t[i]), g.lim[i], "an interval of length tau ending at a charge");
        }
    }

    // TEST-323 verifies: SPEC-CAP-011, REQ-RISK-092, REQ-RISK-093, ATTACK-206
    function testFuzz_TEST_323_noTauIntervalExceedsItsLastLimitNetOfCredits(
        uint32 tauSeed,
        uint64[N] memory gaps,
        uint96[N] memory xs,
        uint96[N] memory ls,
        uint96[N] memory cs,
        uint32 creditBits
    ) public pure {
        (Log memory g, uint256 tau) = _run(tauSeed, gaps, xs, ls, cs, creditBits);
        for (uint256 i = 0; i < g.n; ++i) {
            // Every charge and credit at this timestamp up to the charge belongs to the interval; credits logged at
            // the same timestamp after it only lower the net, so the bound below is the weaker one.
            if (i + 1 < g.n && g.t[i + 1] == g.t[i]) continue;
            uint256 from = g.t[i] >= tau - 1 ? g.t[i] - (tau - 1) : 0;
            uint256 charged = _sum(g, from, g.t[i]);
            uint256 credited = _credits(g, from, g.t[i]);
            uint256 net = charged > credited ? charged - credited : 0;
            assertLe(net, g.lim[i], "net charges in an interval of length tau ending at a charge");
        }
    }

    // TEST-323 verifies: SPEC-CAP-011, ATTACK-205
    // Sources: MATH-AR-85i
    function testFuzz_TEST_323_twoTauHoldsAtMostTwiceTheLargestLimit(
        uint32 tauSeed,
        uint64[N] memory gaps,
        uint96[N] memory xs,
        uint96[N] memory ls
    ) public pure {
        uint96[N] memory none;
        (Log memory g, uint256 tau) = _run(tauSeed, gaps, xs, ls, none, 0);
        uint256 maxLim = 0;
        for (uint256 i = 0; i < g.n; ++i) {
            maxLim = Math.max(maxLim, g.lim[i]);
        }
        for (uint256 i = 0; i < g.n; ++i) {
            uint256 from = g.t[i] >= 2 * tau - 1 ? g.t[i] - (2 * tau - 1) : 0;
            assertLe(_sum(g, from, g.t[i]), 2 * maxLim, "an interval of length 2 tau");
        }
    }

    // TEST-323 verifies: SPEC-CAP-011, REQ-RISK-097
    // Sources: MATH-AR-85g, MATH-AR-88
    function testFuzz_TEST_323_chargesFreeWithinTwoTauAndMoreAtIsExact(
        uint32 tauSeed,
        uint64 start,
        uint96 prev,
        uint96 curr,
        uint64 dt
    ) public pure {
        uint256 tau = bound(tauSeed, 3600, 604_800);
        start = uint64(bound(start, 0, type(uint32).max));
        SpeedWindow memory w = SpeedWindow(start, prev, curr, 0, false);
        uint256 t = uint256(start) + (uint256(dt) % (3 * tau));
        SpeedWindow memory r = SpeedLimitMath.roll(w, tau, t);
        assertGe(t, r.start, "the bucket never starts in the future");
        assertGt(r.start + tau, t, "the check lies in the current bucket");
        assertEq(
            SpeedLimitMath.used(SpeedLimitMath.roll(r, tau, uint256(r.start) + 2 * tau)), 0, "empty at start + 2 tau"
        );
        (uint64 at, uint256 amount) = SpeedLimitMath.moreAt(r, tau);
        if (r.prev > 0) {
            SpeedWindow memory later = SpeedLimitMath.roll(r, tau, at);
            assertEq(SpeedLimitMath.used(later), r.curr, "at moreAt only curr counts");
            assertEq(amount, r.prev);
        } else if (r.curr > 0) {
            assertEq(at, r.start + 2 * tau);
            assertEq(amount, r.curr);
        } else {
            assertEq(at, 0);
            assertEq(amount, 0);
        }
        if (at != 0) {
            assertGt(at, t, "moreAt lies ahead");
            assertLe(at, t + 2 * tau, "and at most two windows ahead");
        }
    }

    // TEST-323 verifies: SPEC-CAP-012, ATTACK-205, ATTACK-206
    // Sources: MATH-AR-86a, MATH-AR-86b, MATH-AR-86c
    function testFuzz_TEST_323_clampBoundsMonotoneAndSplitProof(
        uint16 rateSeed,
        uint96 a,
        uint96 b,
        uint128 d0,
        uint96 used1,
        uint128 liveLater,
        uint32 dt
    ) public pure {
        uint256 rate = bound(rateSeed, 0, 10_000);
        (uint256 lo, uint256 hi) = a <= b ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
        uint256 lim = SpeedLimitMath.limit(rate, lo, hi, d0);
        assertGe(lim, lo);
        assertLe(lim, hi);
        assertGe(SpeedLimitMath.limit(rate, lo, hi, uint256(d0) + 1), lim, "monotone in the base");
        // A charge opens the bucket on base d0; inside the bucket any live base (a borrow raising it, a repay lowering
        // it) gives the limit of d0, whatever the split.
        assertEq(SpeedLimitMath.limit(rate, lo, hi, _baseLater(d0, used1, liveLater, dt)), lim);
    }

    /// @dev The window-start base a check sees `dt % tau` after a charge of `used` opened the bucket on base `d0`,
    /// with the live base then `liveLater`.
    function _baseLater(
        uint256 d0,
        uint256 used,
        uint256 liveLater,
        uint32 dt
    ) internal pure returns (uint256) {
        uint256 tau = 21_600;
        uint256 t0 = 1_762_650_000;
        SpeedWindow memory empty;
        SpeedWindow memory r0 = SpeedLimitMath.roll(empty, tau, t0);
        SpeedWindow memory w = SpeedLimitMath.add(r0, used, SpeedLimitMath.windowBase(empty, r0, d0));
        SpeedWindow memory r = SpeedLimitMath.roll(w, tau, t0 + (uint256(dt) % tau));
        return SpeedLimitMath.windowBase(w, r, liveLater);
    }

    // TEST-323 verifies: SPEC-CAP-013
    // Sources: MATH-AR-87
    function testFuzz_TEST_323_usdChargeIsTheCeiling(
        uint128 amount,
        uint64 price,
        uint8 decSeed
    ) public pure {
        uint8 dec = uint8(bound(decSeed, 0, 18));
        uint256 usd = SpeedLimitMath.usdOf(amount, price, dec);
        uint256 exact = uint256(amount) * price;
        assertGe(usd * 10 ** dec, exact, "never below the exact value");
        assertLt(usd * 10 ** dec, exact + 10 ** dec, "less than one unit above it");
    }
}
