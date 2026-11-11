// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaTest} from "../utils/AvanaTest.sol";
import {RouteMathHarness} from "../utils/harness/RouteMathHarness.sol";

/// @title RouteMathFuzzTest
/// @notice The LitePSM gem amount of a `PegModule` route (REQ-ROUTE-012, MATH-ST-120): the largest amount the DAI buys,
/// never overflowing for DAI below 2^128, and 0 at or above the 10^36 fee cut-off.
contract RouteMathFuzzTest is AvanaTest {
    RouteMathHarness internal m;

    function setUp() public {
        m = new RouteMathHarness();
    }

    function _conversion(
        uint8 gem
    ) internal pure returns (uint256) {
        return gem % 3 == 0 ? 1e12 : (gem % 3 == 1 ? 1e10 : 1);
    }

    // TEST-054 verifies: REQ-ROUTE-012
    function testFuzz_TEST_054_gemAmtIsTheLargestAffordable(
        uint256 dai,
        uint256 tout,
        uint8 gem
    ) public view {
        dai = bound(dai, 0, type(uint128).max);
        tout = tout % 2 == 0 ? bound(tout, 0, 1e16) : bound(tout, 0, 1e36 - 1);
        uint256 c = _conversion(gem);
        uint256 g = m.litePsmGemAmt(dai, tout, c);
        assertLe(m.litePsmCost(g, tout, c), dai, "cost above the DAI held");
        assertGt(m.litePsmCost(g + 1, tout, c), dai, "one more unit was affordable");
    }

    // TEST-054 verifies: REQ-ROUTE-012, REQ-ROUTE-026
    function testFuzz_TEST_054_haltedOrHugeFeeBuysNothing(
        uint256 dai,
        uint256 tout,
        uint8 gem
    ) public view {
        tout = bound(tout, 1e36, type(uint256).max);
        assertEq(m.litePsmGemAmt(dai, tout, _conversion(gem)), 0);
    }

    // TEST-054 verifies: REQ-ROUTE-012
    function test_TEST_054_workedExamples() public view {
        assertEq(m.litePsmGemAmt(1000e18 + 5e11, 0, 1e12), 1_000_000_000);
        assertEq(m.litePsmGemAmt(1001e18, 1e15, 1e12), 1_000_000_000);
        assertEq(m.litePsmCost(1_000_000_000, 1e15, 1e12), 1001e18);
        assertEq(m.litePsmGemAmt(2000e18, 1e14, 1e12), 1_999_800_019);
        assertEq(m.litePsmGemAmt(1e12 - 1, 0, 1e12), 0);
        // The fee floor admits g0 + 1: D = 1 wei, tout = 1, c = 1 (MATH-ST-120 wrong reading).
        assertEq(m.litePsmGemAmt(1, 1, 1), 1);
    }
}
