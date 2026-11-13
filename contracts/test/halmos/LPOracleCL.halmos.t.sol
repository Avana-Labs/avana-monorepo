// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {LPOracleCLMathHarness} from "../utils/harness/LPOracleCLMathHarness.sol";
import {Test} from "forge-std/Test.sol";

/// @title LPOracleCLHalmosTest
/// @notice Symbolic checks of the concentrated-liquidity pricing module (2.10): the oracle square-root price lies in
/// `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)` for every listable price and decimals, so `tickAtSqrtRatio` of the consistency
/// reference never reverts (PROP-025); the mean tick of two cumulatives rounds toward negative infinity and never
/// reverts (SPEC-ORC-010); the clamp makes an out-of-range composition one-sided (SPEC-ORC-006); the tick distance is
/// symmetric and exact.
/// @dev Prices in `[1, 10^18]` (`MAX_ROUTE_ANSWER`), decimals in `[0, 18]`. Checks that time out keep a 10,000-run fuzz
/// twin in `test/fuzz/LPOracleCL.fuzz.t.sol`.
contract LPOracleCLHalmosTest is Test {
    LPOracleCLMathHarness internal h;

    function setUp() public {
        h = new LPOracleCLMathHarness();
    }

    // PROP-025 verifies: SPEC-ORC-009, SPEC-ORC-010, REQ-ORACLE-104, Q-191
    // Sources: MATH-UO-10, MATH-UO-11
    function check_PROP_025_oracleSqrtIsTickable(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public {
        vm.assume(p0 >= 1 && p0 <= 1e18 && p1 >= 1 && p1 <= 1e18 && d0 <= 18 && d1 <= 18);
        h.setMarket(d0, d1, -887_272, 887_272);
        uint160 s = h.oracleSqrt(p0, p1);
        assertGe(s, ClPriceMath.MIN_SQRT_RATIO, "below MIN_SQRT_RATIO");
        assertLt(s, ClPriceMath.MAX_SQRT_RATIO, "at or above MAX_SQRT_RATIO");
    }

    // PROP-025 verifies: SPEC-ORC-010, REQ-ORACLE-014
    function check_PROP_025_meanTickRoundsTowardNegativeInfinity(
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
        if (ok) {
            assertLe(int256(tick) * w, delta, "mean above the exact quotient");
            assertGt((int256(tick) + 1) * w, delta, "mean more than one below");
            assertGe(tick, ClPriceMath.MIN_TICK, "below MIN_TICK");
            assertLe(tick, ClPriceMath.MAX_TICK, "above MAX_TICK");
        } else {
            int256 floorQ = delta >= 0 ? delta / w : -((-delta + w - 1) / w);
            assertTrue(floorQ < ClPriceMath.MIN_TICK || floorQ > ClPriceMath.MAX_TICK, "refused an in-range mean");
        }
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
}
