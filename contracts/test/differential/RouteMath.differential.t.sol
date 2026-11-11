// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteMathHarness} from "../utils/harness/RouteMathHarness.sol";
import {DifferentialTest} from "./utils/DifferentialTest.sol";

/// @title RouteMathDifferentialTest
/// @notice The LitePSM gem amount of a `PegModule` route against the exact Python reference, which finds the largest
/// gem amount by binary search rather than the contract's closed form (REQ-ROUTE-012).
/// @dev DAI amounts up to 2^128 wei, fees from 0 to past the 10^36 cut-off (with weight on realistic fees below 1 %),
/// and the conversion factors of 6-, 8- and 18-decimal gems.
/// forge-config: differential.fuzz.runs = 256
contract RouteMathDifferentialTest is DifferentialTest {
    RouteMathHarness internal m;

    function setUp() public {
        m = new RouteMathHarness();
    }

    // TEST-054 verifies: REQ-ROUTE-012
    function testFuzz_TEST_054_differentialLitePsmGemAmt(
        uint256 dai,
        uint256 tout,
        uint8 gem
    ) public {
        dai = bound(dai, 0, type(uint128).max);
        tout = tout % 4 == 0 ? bound(tout, 0, 1e16) : bound(tout, 0, 2e36);
        uint256 c = gem % 3 == 0 ? 1e12 : (gem % 3 == 1 ? 1e10 : 1);
        uint256[] memory args = new uint256[](3);
        (args[0], args[1], args[2]) = (dai, tout, c);
        assertEq(m.litePsmGemAmt(dai, tout, c), abi.decode(_reference("litePsmGemAmt", args), (uint256)), "gemAmt");
    }

    // TEST-054 verifies: REQ-ROUTE-012
    function test_TEST_054_differentialWorkedExamples() public {
        uint256[3][3] memory cases =
            [[uint256(1000e18 + 5e11), 0, 1e12], [uint256(1001e18), 1e15, 1e12], [uint256(2000e18), 1e14, 1e12]];
        for (uint256 k = 0; k < 3; ++k) {
            uint256[] memory args = new uint256[](3);
            (args[0], args[1], args[2]) = (cases[k][0], cases[k][1], cases[k][2]);
            assertEq(
                m.litePsmGemAmt(cases[k][0], cases[k][1], cases[k][2]),
                abi.decode(_reference("litePsmGemAmt", args), (uint256)),
                "example"
            );
        }
    }
}
