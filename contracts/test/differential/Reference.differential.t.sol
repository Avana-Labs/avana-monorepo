// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DifferentialTest} from "./utils/DifferentialTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ReferenceDifferentialTest
/// @notice Harness check of the differential pipeline: the Python reference and OpenZeppelin `Math.mulDiv` agree on
/// every floor and ceiling, so a later mismatch in an Avana library points at the library.
contract ReferenceDifferentialTest is DifferentialTest {
    /// forge-config: differential.fuzz.runs = 256
    function testFuzz_harness_mulDivMatchesReference(
        uint256 a,
        uint256 b,
        uint256 d,
        bool ceil
    ) public {
        d = bound(d, 1, type(uint256).max);
        // a·b ≤ 2^256 − 1 keeps the exact quotient inside uint256, so both sides are defined.
        if (a > 0) b = bound(b, 0, type(uint256).max / a);
        uint256 expected = abi.decode(_reference("mulDiv", _args(a, b, d, ceil ? 1 : 0)), (uint256));
        uint256 actual = Math.mulDiv(a, b, d, ceil ? Math.Rounding.Ceil : Math.Rounding.Floor);
        assertEq(actual, expected, "mulDiv");
    }
}
