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
/// `check_PROP_111_ownChargesNeverRaiseTheLimit` and `check_PROP_112_usdChargeIsTheCeiling` run through OpenZeppelin
/// `mulDiv` and time out at 60 s per query; their fuzz twins are `testFuzz_TEST_323_clampBoundsMonotoneAndSplitProof`
/// and `testFuzz_TEST_323_usdChargeIsTheCeiling`.
contract SpeedLimitMathHalmosTest is Test {
    uint256 internal constant TAU_MIN = 3600;
    uint256 internal constant TAU_MAX = 604_800;
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
        SpeedWindow memory r1 = SpeedLimitMath.roll(SpeedWindow(start, prev, curr), tau, t1);
        vm.assume(SpeedLimitMath.fits(r1, l1, x1));
        SpeedWindow memory r2 = SpeedLimitMath.roll(SpeedLimitMath.add(r1, x1), tau, t2);
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
        SpeedWindow memory r = SpeedLimitMath.roll(SpeedWindow(start, prev, curr), tau, t);
        assert(r.start >= start && r.start <= t && uint256(r.start) + tau > t);
        SpeedWindow memory w = SpeedLimitMath.add(r, x);
        assert(SpeedLimitMath.used(SpeedLimitMath.roll(w, tau, later)) == 0);
    }

    // PROP-111 verifies: SPEC-CAP-012, REQ-RISK-096
    /// @notice `min ≤ L ≤ max` whenever `min ≤ max`; an all-zero scope gives `L = 0`.
    function check_PROP_111_clampWithinBounds(
        uint16 rate,
        uint96 lo,
        uint96 hi,
        uint128 base,
        uint96 used
    ) public pure {
        vm.assume(rate <= 10_000 && lo <= hi);
        uint256 lim = SpeedLimitMath.limit(rate, lo, hi, base, used);
        assert(lim >= lo && lim <= hi);
        assert(SpeedLimitMath.limit(0, 0, 0, base, used) == 0);
    }

    // PROP-111 verifies: SPEC-CAP-012, ATTACK-205
    /// @notice With `D = D0 + used`, the limit equals the limit of `D0` (own charges never raise it), and it never
    /// decreases when the base grows.
    function check_PROP_111_ownChargesNeverRaiseTheLimit(
        uint16 rate,
        uint96 lo,
        uint96 hi,
        uint128 d0,
        uint96 used,
        uint128 more
    ) public pure {
        vm.assume(rate <= 10_000 && lo <= hi);
        uint256 lim = SpeedLimitMath.limit(rate, lo, hi, d0, 0);
        assert(SpeedLimitMath.limit(rate, lo, hi, uint256(d0) + used, used) == lim);
        assert(SpeedLimitMath.limit(rate, lo, hi, uint256(d0) + more, 0) >= lim);
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
        SpeedWindow memory r = SpeedLimitMath.roll(SpeedWindow(start, prev, curr), tau, t);
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
    /// @notice The USD charge is the ceiling of `amount × price / 10^decimals` for 6- and 18-decimal assets.
    function check_PROP_112_usdChargeIsTheCeiling(
        uint128 amount,
        uint64 price,
        bool eighteen
    ) public pure {
        uint8 dec = eighteen ? 18 : 6;
        uint256 usd = SpeedLimitMath.usdOf(amount, price, dec);
        uint256 exact = uint256(amount) * price;
        assert(usd * 10 ** dec >= exact);
        assert(usd * 10 ** dec < exact + 10 ** dec);
    }
}
