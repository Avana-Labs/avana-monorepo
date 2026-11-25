// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DifferentialTest} from "./utils/DifferentialTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title MathSummariesDifferentialTest
/// @notice The Certora LPOracle spec summarises three libraries instead of proving their bytecode, as Aave's own V4
/// library verification does for mulDiv: OpenZeppelin `Math.mulDiv` and v4-core `FullMath.mulDiv` are floor(x·y/den)
/// and revert when den is 0 or the quotient is not a word, and OpenZeppelin `Math.sqrt` is the integer square root.
/// Each fuzz case hunts a library result that breaks its summary, which would make the LPOracle proofs unsound.
/// The inputs cover the 512-bit path (x·y above 2^256) and every bit length, not just small values.
contract MathSummariesDifferentialTest is DifferentialTest {
    function ozMulDiv(
        uint256 x,
        uint256 y,
        uint256 den
    ) external pure returns (uint256) {
        return Math.mulDiv(x, y, den);
    }

    function fullMathMulDiv(
        uint256 x,
        uint256 y,
        uint256 den
    ) external pure returns (uint256) {
        return FullMath.mulDiv(x, y, den);
    }

    /// @dev Spreads fuzzed words over bit lengths: `x >> shift` has at most 256 - shift bits.
    function _spread(
        uint256 x,
        uint8 shift
    ) internal pure returns (uint256) {
        return x >> shift;
    }

    function _word(
        uint256 x,
        uint256 y,
        uint256 den
    ) internal returns (bool fits, uint256 q) {
        uint256[] memory args = new uint256[](3);
        (args[0], args[1], args[2]) = (x, y, den);
        uint256 f;
        (f, q) = abi.decode(_reference("mulDivWord", args), (uint256, uint256));
        fits = f == 1;
    }

    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_ozMulDiv_matchesFloorOrReverts(
        uint256 x,
        uint256 y,
        uint256 den,
        uint8 sx,
        uint8 sy,
        uint8 sd
    ) public {
        (x, y) = (_spread(x, sx), _spread(y, sy));
        den = bound(_spread(den, sd), 1, type(uint256).max);
        (bool fits, uint256 q) = _word(x, y, den);
        if (!fits) vm.expectRevert();
        uint256 r = this.ozMulDiv(x, y, den);
        if (fits) assertEq(r, q, "OpenZeppelin mulDiv is not floor(x*y/den)");
    }

    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_fullMathMulDiv_matchesFloorOrReverts(
        uint256 x,
        uint256 y,
        uint256 den,
        uint8 sx,
        uint8 sy,
        uint8 sd
    ) public {
        (x, y) = (_spread(x, sx), _spread(y, sy));
        den = bound(_spread(den, sd), 1, type(uint256).max);
        (bool fits, uint256 q) = _word(x, y, den);
        if (!fits) vm.expectRevert();
        uint256 r = this.fullMathMulDiv(x, y, den);
        if (fits) assertEq(r, q, "FullMath mulDiv is not floor(x*y/den)");
    }

    /// The summaries drop the den = 0 path because both libraries revert there.
    function testFuzz_mulDiv_revertsOnZeroDenominator(
        uint256 x,
        uint256 y
    ) public {
        vm.expectRevert();
        this.ozMulDiv(x, y, 0);
        vm.expectRevert();
        this.fullMathMulDiv(x, y, 0);
    }

    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_ozSqrt_isTheIntegerSquareRoot(
        uint256 a,
        uint8 shift
    ) public {
        a = _spread(a, shift);
        uint256[] memory args = new uint256[](1);
        args[0] = a;
        uint256 expected = abi.decode(_reference("floorSqrt", args), (uint256));
        assertEq(Math.sqrt(a), expected, "OpenZeppelin sqrt is not floor(sqrt(a))");
    }

    /// Perfect squares and their neighbours, where an off-by-one in the last Newton step would show.
    function testFuzz_ozSqrt_exactAroundPerfectSquares(
        uint128 r
    ) public pure {
        uint256 s = uint256(r) * uint256(r);
        assertEq(Math.sqrt(s), r, "sqrt of a perfect square");
        if (s > 0) assertEq(Math.sqrt(s - 1), uint256(r) - 1, "sqrt just below a perfect square");
        if (r < type(uint128).max) assertEq(Math.sqrt(s + 2 * uint256(r)), r, "sqrt just below the next square");
    }
}
