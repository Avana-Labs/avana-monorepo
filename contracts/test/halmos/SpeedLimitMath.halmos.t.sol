// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpeedLimitMath} from "../../src/policy/risk-module/SpeedLimitMath.sol";
import {SpeedWindow} from "../../src/policy/risk-module/types/SpeedWindow.sol";
import {Test} from "forge-std/Test.sol";

/// @title SpeedLimitMathHalmosTest
/// @notice Symbolic checks of the speed-window arithmetic (2.7 SPEC-CAP-011 to SPEC-CAP-013) for every input inside
/// the bounds of 5.2: the window bound over any two passing charges within τ (PROP-110), the clamp (PROP-111), and the
/// next-capacity time and USD ceiling (PROP-112).
/// @dev Window lengths are within the ParameterStore bounds `[3,600, 604,800]`, amounts `uint96`, timestamps below 2^40.
/// The checks that run through OpenZeppelin `mulDiv` (`check_PROP_111_ownChargesNeverRaiseTheLimitBaseGrows`,
/// `check_PROP_112_usdChargeIsTheCeilingDec6` and `Dec18`) prove that the code equals a reference formula with the same
/// products and divisions; MATH-AR-86 and MATH-AR-87 (`docs/spec/05-verification/z3/aave-risk/ar16_speed_limits.py`)
/// prove the formula's inequality with exact integers. Asserting the inequality here made the solver derive floor and
/// remainder facts through division circuits, and the checks before the split did not finish within 5 hours (run
/// 43492412351). Their fuzz twins are `testFuzz_TEST_323_clampBoundsMonotoneAndSplitProof` and
/// `testFuzz_TEST_323_usdChargeIsTheCeiling`.
contract SpeedLimitMathHalmosTest is Test {
    uint256 internal constant TAU_MIN = 3600;
    uint256 internal constant TAU_MAX = 604_800;
    uint256 internal constant BPS = 10_000;
    /// @dev Block timestamps stay below 2^40 seconds (about 34,800 years), so `start + 2τ` never wraps `uint64`.
    uint256 internal constant TIME_MAX = 1 << 40;

    function _tau(
        uint32 tau
    ) internal pure {
        vm.assume(tau >= TAU_MIN && tau <= TAU_MAX);
    }

    // PROP-110 verifies: SPEC-CAP-011, REQ-RISK-092, REQ-RISK-093, INV-110
    /// @notice From any stored window, two passing charges `x1` at `t1` and `x2` at `t2` with `t1 ≤ t2 < t1 + τ` total
    /// at most the second check's limit; the first check's window total stays within the limit it passed.
    function check_PROP_110_twoChargesWithinTauFitTheLastLimit(
        uint32 tau,
        uint64 start,
        uint96 prev,
        uint96 curr,
        uint64 t1,
        uint64 t2,
        uint96 x1,
        uint96 x2,
        uint96 l1,
        uint96 l2
    ) public pure {
        _tau(tau);
        vm.assume(start <= t1 && t1 <= t2 && uint256(t2) < uint256(t1) + tau && t2 < TIME_MAX);
        SpeedWindow memory r1 = SpeedLimitMath.roll(SpeedWindow(start, prev, curr, 0, false), tau, t1);
        vm.assume(SpeedLimitMath.fits(r1, l1, x1));
        SpeedWindow memory r2 = SpeedLimitMath.roll(SpeedLimitMath.add(r1, x1, 0), tau, t2);
        vm.assume(SpeedLimitMath.fits(r2, l2, x2));
        assert(uint256(x1) + x2 <= l2);
        assert(SpeedLimitMath.used(r1) + x1 <= l1);
    }

    // PROP-110 verifies: SPEC-CAP-011, REQ-RISK-097
    /// @notice A charge made at `t` counts at no check from `t + 2τ`; the rollover never moves `start` backward and
    /// never past the check time.
    function check_PROP_110_chargeFreesWithinTwoTau(
        uint32 tau,
        uint64 start,
        uint96 prev,
        uint96 curr,
        uint64 t,
        uint96 x,
        uint64 later
    ) public pure {
        _tau(tau);
        vm.assume(start <= t && uint256(later) >= uint256(t) + 2 * uint256(tau) && later < TIME_MAX);
        SpeedWindow memory r = SpeedLimitMath.roll(SpeedWindow(start, prev, curr, 0, false), tau, t);
        assert(r.start >= start && r.start <= t && uint256(r.start) + tau > t);
        SpeedWindow memory w = SpeedLimitMath.add(r, x, 0);
        assert(SpeedLimitMath.used(SpeedLimitMath.roll(w, tau, later)) == 0);
    }

    // PROP-111 verifies: SPEC-CAP-012, REQ-RISK-096
    /// @notice `min ≤ L ≤ max` whenever `min ≤ max`; an all-zero scope gives `L = 0`.
    function check_PROP_111_clampWithinBounds(
        uint16 rate,
        uint96 lo,
        uint96 hi,
        uint128 base
    ) public pure {
        vm.assume(rate <= 10_000 && lo <= hi);
        uint256 lim = SpeedLimitMath.limit(rate, lo, hi, base);
        assert(lim >= lo && lim <= hi);
        assert(SpeedLimitMath.limit(0, 0, 0, base) == 0);
    }

    // PROP-111 verifies: SPEC-CAP-012, ATTACK-205, ATTACK-206
    /// @notice Inside the bucket a charge of `used` at `t0` opened on base `d0`, a check `dt` later reads the
    /// window-start base `d0` whatever the live base (own charges never raise it, repays never lower it), so its limit
    /// is the limit of `d0` for every rate, `min` and `max`. The three `ownChargesNeverRaiseTheLimit` checks replace one
    /// check (rate ≤ 10⁴, `min ≤ max < 2^96`, `d0 < 2^128`, `used < 2^96`, `live < 2^128`, `t0 < 2^40`, `dt < τ` with
    /// τ = 3,600) that asserted `limit(base) == limit(d0)` and `limit(d0 + 1) ≥ limit(d0)` and did not finish within
    /// 5 hours. `SameBucket` and `NextBucket` split its window inputs by whether the check at `t0 + dt` falls in the
    /// bucket the charge opened (always when `t0 ≥ 2τ`, where the bucket starts at `t0`); `BaseGrows` proves the
    /// monotonicity for every rate, `min`, `max` and base up to 2^128 (so for `d0` and `d0 + 1`). `limit` is a function
    /// of `(rate, min, max, base)`, so an equal base gives an equal limit; this check asserts the base and calls no
    /// `mulDiv`.
    function check_PROP_111_ownChargesNeverRaiseTheLimitSameBucket(
        uint128 d0,
        uint96 used,
        uint128 live,
        uint64 t0,
        uint32 dt
    ) public pure {
        vm.assume(t0 < TIME_MAX && dt < TAU_MIN);
        SpeedWindow memory w = _chargeOpening(d0, used, t0);
        vm.assume(uint256(t0) + dt < uint256(w.start) + TAU_MIN);
        assert(_baseAt(w, live, uint256(t0) + dt) == d0);
    }

    // PROP-111 verifies: SPEC-CAP-012, ATTACK-205, ATTACK-206
    /// @notice `check_PROP_111_ownChargesNeverRaiseTheLimitSameBucket` when the check at `t0 + dt` falls in the next
    /// bucket. That happens only for `t0 < 2τ`: the charge's bucket then starts at 0 (`t0 < τ`) or at τ
    /// (`τ ≤ t0 < 2τ`), at or before `t0`, so `t0 + dt` can pass its end. The base is then read anew, `sat(live − used)`:
    /// the live base less the bucket before, which holds the charge (SPEC-CAP-012), so the charge still does not raise
    /// it. The check before the split asserted the limit of `d0` here too, which does not hold: `t0 = 7,000`, `dt = 500`,
    /// `d0 = 10⁶`, `live = 0`, rate 10⁴, `min = 0`, `max = 10⁶` gives `limit(d0) = 10⁶` and `limit(base) = 0`.
    function check_PROP_111_ownChargesNeverRaiseTheLimitNextBucket(
        uint128 d0,
        uint96 used,
        uint128 live,
        uint64 t0,
        uint32 dt
    ) public pure {
        vm.assume(t0 < TIME_MAX && dt < TAU_MIN);
        SpeedWindow memory w = _chargeOpening(d0, used, t0);
        vm.assume(uint256(t0) + dt >= uint256(w.start) + TAU_MIN);
        assert(_baseAt(w, live, uint256(t0) + dt) == (live > used ? uint256(live) - used : 0));
    }

    // PROP-111 verifies: SPEC-CAP-012, ATTACK-205, ATTACK-206
    /// @notice `limit(rate, min, max, base)` is the reference `min(max, max(min, ⌊rate × base / 10⁴⌋))`, the terms
    /// `Math.mulDiv` forms when the product fits 256 bits, for every rate ≤ 10⁴, `min ≤ max < 2^96` and base ≤ 2^128.
    /// MATH-AR-86f (`docs/spec/05-verification/z3/aave-risk/ar16_speed_limits.py`) proves with exact integers that the
    /// reference never decreases when the base grows by 1 (MATH-AR-86b for any larger base). Applied at `d0` and
    /// `d0 + 1`, both at most 2^128, this gives `limit(d0 + 1) ≥ limit(d0)`, the second assertion of the check before the
    /// split. The assumption rules out the 512-bit branch of `mulDiv`: `rate × base ≤ 10⁴ × 2^128 < 2^142`, so it removes
    /// no input.
    function check_PROP_111_ownChargesNeverRaiseTheLimitBaseGrows(
        uint256 rate,
        uint256 lo,
        uint256 hi,
        uint256 base
    ) public pure {
        vm.assume(rate <= BPS && lo <= hi && hi < 2 ** 96 && base <= 2 ** 128);
        _assumeExactProduct(rate, base);
        uint256 q;
        unchecked {
            q = rate * base / BPS;
        }
        uint256 want = q < lo ? lo : q;
        if (want > hi) want = hi;
        assert(SpeedLimitMath.limit(rate, lo, hi, base) == want);
    }

    /// @dev The stored window after a charge of `used` at `t0` opened the bucket of an empty window on base `d0`.
    function _chargeOpening(
        uint256 d0,
        uint256 used,
        uint64 t0
    ) internal pure returns (SpeedWindow memory w) {
        SpeedWindow memory empty;
        SpeedWindow memory r0 = SpeedLimitMath.roll(empty, TAU_MIN, t0);
        w = SpeedLimitMath.add(r0, used, SpeedLimitMath.windowBase(empty, r0, d0));
    }

    /// @dev The window-start base a check at `t` reads from the stored window `w` when the live base is `live`.
    function _baseAt(
        SpeedWindow memory w,
        uint256 live,
        uint256 t
    ) internal pure returns (uint256) {
        return SpeedLimitMath.windowBase(w, SpeedLimitMath.roll(w, TAU_MIN, t), live);
    }

    // PROP-111 verifies: SPEC-CAP-011
    /// @notice A credit never raises `used`, takes exactly `min(x, used)` and never goes below zero.
    function check_PROP_111_creditTakesAtMostWhatCounts(
        uint32 tau,
        uint64 start,
        uint96 prev,
        uint96 curr,
        uint64 t,
        uint96 x
    ) public pure {
        _tau(tau);
        vm.assume(start <= t && t < TIME_MAX);
        SpeedWindow memory w = SpeedWindow(start, prev, curr, 0, false);
        uint256 before = SpeedLimitMath.used(SpeedLimitMath.roll(w, tau, t));
        uint256 afterCredit = SpeedLimitMath.used(SpeedLimitMath.roll(SpeedLimitMath.credit(w, tau, t, x), tau, t));
        assert(afterCredit <= before);
        assert(before - afterCredit == (x < before ? x : before));
    }

    // PROP-112 verifies: SPEC-CAP-011, REQ-RISK-097
    /// @notice With `prev > 0`, at `moreAt = start + τ` the window holds exactly `curr`; with only `curr > 0` it is
    /// empty at `start + 2τ`; `moreAt` lies after the check and at most `2τ` ahead.
    function check_PROP_112_moreAtReleasesWhatItSays(
        uint32 tau,
        uint64 start,
        uint96 prev,
        uint96 curr,
        uint64 t
    ) public pure {
        _tau(tau);
        vm.assume(start <= t && t < TIME_MAX);
        SpeedWindow memory r = SpeedLimitMath.roll(SpeedWindow(start, prev, curr, 0, false), tau, t);
        (uint64 at, uint256 amount) = SpeedLimitMath.moreAt(r, tau);
        if (r.prev > 0) {
            assert(amount == r.prev);
            assert(SpeedLimitMath.used(SpeedLimitMath.roll(r, tau, at)) == r.curr);
        } else if (r.curr > 0) {
            assert(amount == r.curr);
            assert(SpeedLimitMath.used(SpeedLimitMath.roll(r, tau, at)) == 0);
        } else {
            assert(at == 0 && amount == 0);
        }
        if (at != 0) assert(at > t && uint256(at) <= uint256(t) + 2 * uint256(tau));
    }

    // PROP-112 verifies: SPEC-CAP-013
    /// @notice The USD charge is the ceiling of `amount × price / 10^decimals` for 6-decimal assets, every
    /// `amount < 2^128` and `price < 2^64` (see `_usdIsTheReference`). The two `usdChargeIsTheCeiling` checks take the
    /// two decimals of the check before the split (6 and 18, which it selected by a `bool`), one per check, so together
    /// they cover its inputs.
    function check_PROP_112_usdChargeIsTheCeilingDec6(
        uint256 amount,
        uint256 price
    ) public pure {
        _usdIsTheReference(amount, price, 6, 1e6);
    }

    // PROP-112 verifies: SPEC-CAP-013
    /// @notice `check_PROP_112_usdChargeIsTheCeilingDec6` for 18-decimal assets.
    function check_PROP_112_usdChargeIsTheCeilingDec18(
        uint256 amount,
        uint256 price
    ) public pure {
        _usdIsTheReference(amount, price, 18, 1e18);
    }

    /// @dev `usdOf(amount, price, dec)` is `u = ⌊P / 10^dec⌋ + (mulmod(amount, price, 10^dec) > 0 ? 1 : 0)` with
    /// `P = amount × price`, the terms `Math.mulDiv` with rounding up forms when the product fits 256 bits, so the
    /// assertion holds by equal terms. `mulmod` is the exact remainder `P mod 10^dec`, and MATH-AR-87d
    /// (`docs/spec/05-verification/z3/aave-risk/ar16_speed_limits.py`) proves with exact integers that this `u` has
    /// `u × 10^dec ≥ P` and `u × 10^dec < P + 10^dec` for every `P < 2^192`: the assertions of the check before the split,
    /// which made the solver derive the floor and the remainder of a 192-bit product through division circuits. The
    /// assumption rules out the 512-bit branch of `mulDiv`: `P < 2^192` (MATH-AR-87c), so it removes no input.
    function _usdIsTheReference(
        uint256 amount,
        uint256 price,
        uint8 dec,
        uint256 unit
    ) internal pure {
        vm.assume(amount < 2 ** 128 && price < 2 ** 64);
        _assumeExactProduct(amount, price);
        uint256 p;
        unchecked {
            p = amount * price;
        }
        uint256 want = p / unit + (mulmod(amount, price, unit) > 0 ? 1 : 0);
        assert(SpeedLimitMath.usdOf(amount, price, dec) == want);
    }

    /// @dev Assumes `mulmod(x, y, 2^256 − 1) == x × y` (and `== y × x`). Every caller passes `x × y < 2^256 − 1`, where
    /// both sides are the exact product, so the assumption removes no input. It states, without a multiplication, the
    /// fact `Math.mulDiv` tests first: the high word of the 512-bit product is 0. Both operand orders are given because
    /// the optimizer may emit either order for the code's `x * y`.
    function _assumeExactProduct(
        uint256 x,
        uint256 y
    ) internal pure {
        unchecked {
            vm.assume(mulmod(x, y, type(uint256).max) == x * y);
            vm.assume(mulmod(x, y, type(uint256).max) == y * x);
        }
    }
}
