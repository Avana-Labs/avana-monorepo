// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {ClPriceMathHarness} from "../utils/harness/ClPriceMathHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ClPriceMathSqrtPriceFuzzTest
/// @notice TEST-079: the integer square-root price the concentrated-liquidity LPOracle computes from two feed prices
/// (`SPEC-ORC-009`), over the whole input domain the callers allow (prices in `[1, 2^128)`, decimals up to 18), lands
/// in `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)` and never reverts; and the reference tick taken from it (`SPEC-ORC-010`) is the
/// exact tick of the feed ratio or one below.
contract ClPriceMathSqrtPriceFuzzTest is AvanaTest {
    ClPriceMathHarness internal m;

    function setUp() public {
        m = new ClPriceMathHarness();
    }

    function _inputs(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (uint256, uint256, uint8, uint8) {
        return (
            bound(p0, 1, type(uint128).max),
            bound(p1, 1, type(uint128).max),
            uint8(bound(d0, 0, 18)),
            uint8(bound(d1, 0, 18))
        );
    }

    // TEST-079 verifies: SPEC-ORC-009, REQ-ORACLE-012, Q-191
    // Sources: 5.1 TEST-079, MATH-UO-11, MATH-UO-12
    /// @notice The result is always inside `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)`; it sits at a bound exactly when it is
    /// reported clamped, and the exact root `s*` lies below `s + 3` in the lower branch.
    /// @dev Kills: a saturation or truncation that leaves the tick domain, a revert on an extreme ratio, and a clamp
    /// flag that disagrees with the result.
    function testFuzz_TEST_079_sqrtPriceInRange(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public view {
        (p0, p1, d0, d1) = _inputs(p0, p1, d0, d1);
        (uint160 s, bool clamped) = m.oracleSqrtPrice(p0, p1, d0, d1);
        assertGe(s, ClPriceMath.MIN_SQRT_RATIO, "at or above MIN_SQRT_RATIO");
        assertLt(s, ClPriceMath.MAX_SQRT_RATIO, "below MAX_SQRT_RATIO");
        if (clamped) {
            assertTrue(s == ClPriceMath.MIN_SQRT_RATIO || s == ClPriceMath.MAX_SQRT_RATIO - 1, "clamped to a bound");
        }
        uint256 num = p0 * 10 ** d1;
        uint256 den = p1 * 10 ** d0;
        if (!clamped && num < den << 64 && s < 2 ** 127) {
            // Branch (a): s = floor(sqrt(X)) with X = floor(num * 2^192 / den), so s*^2 < X + 1 <= (s + 1)^2.
            uint256 x = Math.mulDiv(num, 2 ** 192, den);
            assertLe(uint256(s) * s, x, "never above the root");
            assertGt((uint256(s) + 1) * (uint256(s) + 1), x, "the floored root");
        }
    }

    // TEST-079 verifies: SPEC-ORC-010, SPEC-ORC-009, Q-191
    // Sources: 5.1 TEST-079 ("the reference tick is the exact tick or one below")
    /// @notice With `t = tickAtSqrtRatio(s)` for an unclamped `s`: `sqrtRatioAtTick(t) <= s <= s*`, so `t` is at most the
    /// exact tick; and `s* < s + e` (`e = 3` below `2^128`, `2^32 + 1` above) stays below `sqrtRatioAtTick(t + 2) - 1`,
    /// so the exact tick is at most `t + 1`.
    /// @dev Kills: a reference tick more than one below the exact tick (a coarser root), or above it (a root rounded up).
    function testFuzz_TEST_079_tickExactOrOneBelow(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public view {
        (p0, p1, d0, d1) = _inputs(p0, p1, d0, d1);
        (uint160 s, bool clamped) = m.oracleSqrtPrice(p0, p1, d0, d1);
        vm.assume(!clamped);
        int24 t = m.tickAtSqrtRatio(s);
        assertLe(m.sqrtRatioAtTick(t), s, "the tick's price is at or below s");
        if (t + 1 <= ClPriceMath.MAX_TICK) assertGt(m.sqrtRatioAtTick(t + 1), s, "the greatest such tick");
        if (t + 2 > ClPriceMath.MAX_TICK) return;
        uint256 e = s < 2 ** 128 ? 3 : 2 ** 32 + 1;
        assertGt(uint256(m.sqrtRatioAtTick(t + 2)), uint256(s) + e + 1, "the exact tick is at most t + 1");
    }
}
