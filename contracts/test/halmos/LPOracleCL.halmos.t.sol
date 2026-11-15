// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {LPOracleCLMathHarness} from "../utils/harness/LPOracleCLMathHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @title LPOracleCLHalmosTest
/// @notice Symbolic checks of the concentrated-liquidity pricing module (2.10): the oracle square-root price lies in
/// `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)` for every listable price and decimals, so `tickAtSqrtRatio` of the consistency
/// reference never reverts (PROP-025); the mean tick of two cumulatives rounds toward negative infinity and never
/// reverts (SPEC-ORC-010); the clamp makes an out-of-range composition one-sided (SPEC-ORC-006); the tick distance is
/// symmetric and exact.
/// @dev Prices in `[1, 10^18]` (`MAX_ROUTE_ANSWER`), decimals in `[0, 18]`. Every check keeps a 10,000-run fuzz twin
/// in `test/fuzz/LPOracleCL.fuzz.t.sol`. The oracle square-root checks call `ClPriceMath.oracleSqrtPrice`, compiled
/// into this contract, so the test can recompute the code's own `Math.mulDiv` and `Math.sqrt` terms; the module's
/// `_oracleSqrt` passes the stored decimals to it unchanged. They are split by branch of `SPEC-ORC-009` and by the
/// range of the square-root input (MATH-UO-81). The mean-tick check proves the module returns the rounding formula
/// that MATH-UO-80 proves is the floor.
contract LPOracleCLHalmosTest is Test {
    LPOracleCLMathHarness internal h;

    function setUp() public {
        h = new LPOracleCLMathHarness();
    }

    // PROP-025 verifies: SPEC-ORC-009, SPEC-ORC-010, REQ-ORACLE-104, Q-191
    // Sources: MATH-UO-10, MATH-UO-11, MATH-UO-81
    /// @notice Lower branch of `SPEC-ORC-009` (`num < 2^64 · den`) with the square-root input `X < 2^64`: the oracle
    /// square-root price is in `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)`.
    /// @dev The nine `oracleSqrtIsTickable` checks partition the inputs of the check before the split (prices in
    /// `[1, 10^18]`, decimals at most 18): `Clamped` takes `num >= 2^128 · den`; the four `Upper` checks take
    /// `2^64 · den <= num < 2^128 · den` and split `Y = mulDiv(num, 2^128, den)` at `2^64`, `2^128` and `2^192`; the
    /// four `Lower` checks take `num < 2^64 · den` and split `X = mulDiv(num, 2^192, den)` the same way. The ranges
    /// cover every `uint256`. The test computes `X` and `Y` with the code's own operations, so a path on which the test
    /// reverts is one on which the code reverts. The check before the split ran out of its 5-hour budget (run
    /// 43677588077): bounding `Math.sqrt` of a symbolic input needs its six divisions by symbolic values. Each check
    /// now meets about 32 of the 128 square-root paths, and the lower branch assumes the MATH-UO-81 bound on the root.
    function check_PROP_025_oracleSqrtIsTickableLowerX64(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public pure {
        _lowerBranchTickable(p0, p1, d0, d1, 0, 2 ** 64 - 1);
    }

    // PROP-025 verifies: SPEC-ORC-009, SPEC-ORC-010, REQ-ORACLE-104, Q-191
    /// @notice `check_PROP_025_oracleSqrtIsTickableLowerX64` with `2^64 <= X < 2^128`.
    function check_PROP_025_oracleSqrtIsTickableLowerX128(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public pure {
        _lowerBranchTickable(p0, p1, d0, d1, 2 ** 64, 2 ** 128 - 1);
    }

    // PROP-025 verifies: SPEC-ORC-009, SPEC-ORC-010, REQ-ORACLE-104, Q-191
    /// @notice `check_PROP_025_oracleSqrtIsTickableLowerX64` with `2^128 <= X < 2^192`.
    function check_PROP_025_oracleSqrtIsTickableLowerX192(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public pure {
        _lowerBranchTickable(p0, p1, d0, d1, 2 ** 128, 2 ** 192 - 1);
    }

    // PROP-025 verifies: SPEC-ORC-009, SPEC-ORC-010, REQ-ORACLE-104, Q-191
    /// @notice `check_PROP_025_oracleSqrtIsTickableLowerX64` with `X >= 2^192`.
    function check_PROP_025_oracleSqrtIsTickableLowerX256(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public pure {
        _lowerBranchTickable(p0, p1, d0, d1, 2 ** 192, type(uint256).max);
    }

    // PROP-025 verifies: SPEC-ORC-009, SPEC-ORC-010, REQ-ORACLE-104, Q-191
    /// @notice From `num >= 2^128 · den` the oracle square-root price is `MAX_SQRT_RATIO − 1`, inside the range.
    function check_PROP_025_oracleSqrtIsTickableClamped(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public pure {
        (uint256 num, uint256 den) = _sqrtOperands(p0, p1, d0, d1);
        vm.assume(num >= den << 64 && num >> 128 >= den);
        _assertTickable(p0, p1, d0, d1);
    }

    // PROP-025 verifies: SPEC-ORC-009, SPEC-ORC-010, REQ-ORACLE-104, Q-191
    /// @notice Upper branch of `SPEC-ORC-009` (`2^64 · den <= num < 2^128 · den`) with the square-root input
    /// `Y < 2^64`: the oracle square-root price is in `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)`. MATH-UO-11c shows
    /// `Y >= 2^192` in this branch; the solver does not know it, so the lower ranges get their own checks.
    function check_PROP_025_oracleSqrtIsTickableUpperY64(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public pure {
        _upperBranchTickable(p0, p1, d0, d1, 0, 2 ** 64 - 1);
    }

    // PROP-025 verifies: SPEC-ORC-009, SPEC-ORC-010, REQ-ORACLE-104, Q-191
    /// @notice `check_PROP_025_oracleSqrtIsTickableUpperY64` with `2^64 <= Y < 2^128`.
    function check_PROP_025_oracleSqrtIsTickableUpperY128(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public pure {
        _upperBranchTickable(p0, p1, d0, d1, 2 ** 64, 2 ** 128 - 1);
    }

    // PROP-025 verifies: SPEC-ORC-009, SPEC-ORC-010, REQ-ORACLE-104, Q-191
    /// @notice `check_PROP_025_oracleSqrtIsTickableUpperY64` with `2^128 <= Y < 2^192`.
    function check_PROP_025_oracleSqrtIsTickableUpperY192(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public pure {
        _upperBranchTickable(p0, p1, d0, d1, 2 ** 128, 2 ** 192 - 1);
    }

    // PROP-025 verifies: SPEC-ORC-009, SPEC-ORC-010, REQ-ORACLE-104, Q-191
    /// @notice `check_PROP_025_oracleSqrtIsTickableUpperY64` with `Y >= 2^192`.
    function check_PROP_025_oracleSqrtIsTickableUpperY256(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public pure {
        _upperBranchTickable(p0, p1, d0, d1, 2 ** 192, type(uint256).max);
    }

    // PROP-025 verifies: SPEC-ORC-010, REQ-ORACLE-014
    // Sources: MATH-UO-12d, MATH-UO-80
    /// @notice The mean tick of two cumulatives is `F = trunc(δ / W) − [δ < 0 and δ mod W ≠ 0]`, with `δ` the
    /// difference wrapped to 56 bits and `trunc` the EVM signed division, and is refused exactly when `F` is outside
    /// `[MIN_TICK, MAX_TICK]`, for every pair of `int56` cumulatives and every window in `[1, 2^32)`.
    /// @dev Proved in two parts. This check: `meanOf` returns `F`, with `ok` exactly when `F` is in range, computed here
    /// with the same signed division and remainder. MATH-UO-80
    /// (`docs/spec/05-verification/z3/units-oracle/uo20_halmos_references.py`) proves, over the same inputs, that `F`
    /// is the floor `⌊δ / W⌋` (`F · W <= δ < (F + 1) · W`, and no other integer satisfies it), so the mean rounds
    /// toward negative infinity and a refusal means the floor is out of range: the assertions this check made before
    /// the split. That form multiplied the symbolic mean by the symbolic window and divided a second time by it, and
    /// ran out of its 5-hour budget (run 43677588077).
    function check_PROP_025_meanTickRoundsTowardNegativeInfinityFormula(
        int56 c0,
        int56 c1,
        uint32 window
    ) public view {
        vm.assume(window > 0);
        (bool ok, int24 tick) = h.meanOf(c0, c1, window);
        int256 delta;
        unchecked {
            delta = int256(int56(int256(c1) - int256(c0)));
        }
        int256 w = int256(uint256(window));
        int256 mean = delta / w;
        if (delta < 0 && delta % w != 0) --mean;
        assertEq(ok, mean >= ClPriceMath.MIN_TICK && mean <= ClPriceMath.MAX_TICK, "refusal is not the range test");
        if (ok) assertEq(int256(tick), mean, "mean is not the formula");
    }

    // PROP-025 verifies: SPEC-ORC-006, REQ-ORACLE-104, REQ-AMM-V3-005
    // Sources: AMM-A4a, AMM-A4b
    /// @dev On the range [-10, 10] of two 6-decimal tokens, a price ratio outside the range composes to one token only.
    function check_PROP_025_outOfRangeIsOneSided(
        uint256 p0,
        uint256 p1,
        uint64 units
    ) public {
        vm.assume(p0 >= 1e6 && p0 <= 1e10 && p1 >= 1e6 && p1 <= 1e10);
        h.setMarket(6, 6, -10, 10);
        (bool ok, uint256 a0, uint256 a1) = h.composition(units, p0, p1);
        assertTrue(ok, "composition refused valid prices");
        uint160 s = h.oracleSqrt(p0, p1);
        if (s <= ClPriceMath.sqrtRatioAtTick(-10)) assertEq(a1, 0, "below the range holds token1");
        if (s >= ClPriceMath.sqrtRatioAtTick(10)) assertEq(a0, 0, "above the range holds token0");
    }

    // PROP-025 verifies: SPEC-ORC-010
    function check_PROP_025_tickDistanceIsSymmetricAndExact(
        int24 a,
        int24 b
    ) public view {
        uint256 d = h.tickDistance(a, b);
        assertEq(d, h.tickDistance(b, a), "asymmetric");
        int256 diff = int256(a) - int256(b);
        assertEq(int256(d), diff < 0 ? -diff : diff, "inexact");
    }

    /// @dev Lower branch with `lo <= X <= hi`, `X = mulDiv(num, 2^192, den)` computed as the code computes it. Assumes
    /// `Math.sqrt(X) < 2^129`: MATH-UO-81 proves `Math.sqrt(a) < 2^129` for every `uint256 a` (OpenZeppelin 5.1.0;
    /// each Newton step stays in `[2^e, 2^(e+2))` where `2^(2e) <= a < 2^(2e+2)`), so the assumption removes no input.
    /// The code's root is the same term, so no query divides by a symbolic value at the bit level.
    function _lowerBranchTickable(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1,
        uint256 lo,
        uint256 hi
    ) internal pure {
        (uint256 num, uint256 den) = _sqrtOperands(p0, p1, d0, d1);
        vm.assume(num < den << 64);
        uint256 x = Math.mulDiv(num, ClPriceMath.Q192, den);
        vm.assume(x >= lo && x <= hi);
        vm.assume(Math.sqrt(x) < 2 ** 129);
        _assertTickable(p0, p1, d0, d1);
    }

    /// @dev Upper branch, not clamped, with `lo <= Y <= hi`, `Y = mulDiv(num, 2^128, den)` computed as the code
    /// computes it. No assumption on the root: the code lowers a root at or above `MAX_SQRT_RATIO` to
    /// `MAX_SQRT_RATIO − 1`.
    function _upperBranchTickable(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1,
        uint256 lo,
        uint256 hi
    ) internal pure {
        (uint256 num, uint256 den) = _sqrtOperands(p0, p1, d0, d1);
        vm.assume(num >= den << 64 && num >> 128 < den);
        uint256 y = Math.mulDiv(num, ClPriceMath.Q128, den);
        vm.assume(y >= lo && y <= hi);
        _assertTickable(p0, p1, d0, d1);
    }

    /// @dev `num = p0 · 10^d1` and `den = p1 · 10^d0` as `ClPriceMath` forms them, for prices in `[1, 10^18]` and
    /// decimals at most 18.
    function _sqrtOperands(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (uint256 num, uint256 den) {
        vm.assume(p0 >= 1 && p0 <= 1e18 && p1 >= 1 && p1 <= 1e18 && d0 <= 18 && d1 <= 18);
        num = p0 * 10 ** d1;
        den = p1 * 10 ** d0;
    }

    function _assertTickable(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal pure {
        uint160 s = ClPriceMath.oracleSqrtPrice(p0, p1, d0, d1);
        assertGe(s, ClPriceMath.MIN_SQRT_RATIO, "below MIN_SQRT_RATIO");
        assertLt(s, ClPriceMath.MAX_SQRT_RATIO, "at or above MAX_SQRT_RATIO");
    }
}
