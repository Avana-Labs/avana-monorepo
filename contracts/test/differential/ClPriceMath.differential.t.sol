// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {ClPriceMathHarness} from "../utils/harness/ClPriceMathHarness.sol";
import {DifferentialTest} from "./utils/DifferentialTest.sol";

/// @title ClPriceMathDifferentialTest
/// @notice FFI differential fuzzing of ClPriceMath against the exact Python reference: the tick map (Uniswap's integer
/// algorithm, whose rounding is part of the spec), its inverse by bisection over that map, the oracle square-root price
/// of `SPEC-ORC-009` with both clamps, the clamped composition of `SPEC-AMM-V3-001` and the vault decimals of
/// `SPEC-ORC-005` over it.
/// @dev Run with `FOUNDRY_PROFILE=differential forge test`. Ticks cross FFI offset by `MAX_TICK`.
contract ClPriceMathDifferentialTest is DifferentialTest {
    uint256 internal constant OFFSET = 887_272;

    ClPriceMathHarness internal m;

    function setUp() public {
        m = new ClPriceMathHarness();
    }

    // TEST-037 verifies: SPEC-ORC-006, SPEC-AMM-V3-001
    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_TEST_037_tickMapMatchesReference(
        int24 tickSeed
    ) public {
        int24 t = int24(bound(int256(tickSeed), ClPriceMath.MIN_TICK, ClPriceMath.MAX_TICK));
        uint256 off = uint256(int256(t) + int256(OFFSET));
        uint256[] memory args = new uint256[](1);
        args[0] = off;
        uint256 expected = abi.decode(_reference("sqrtRatioAtTick", args), (uint256));
        uint160 s = m.sqrtRatioAtTick(t);
        assertEq(s, expected, "sqrtRatioAtTick");
        if (t < ClPriceMath.MAX_TICK) {
            args[0] = s + uint160(uint256(int256(tickSeed)) % 1000);
            if (args[0] < ClPriceMath.MAX_SQRT_RATIO) {
                uint256 tickOff = abi.decode(_reference("tickAtSqrtRatio", args), (uint256));
                assertEq(int256(m.tickAtSqrtRatio(uint160(args[0]))), int256(tickOff) - int256(OFFSET), "tick");
            }
        }
    }

    // TEST-037 verifies: SPEC-ORC-009, REQ-ORACLE-012
    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_TEST_037_oracleSqrtPriceMatchesReference(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public {
        p0 = bound(p0, 1, 1e12);
        p1 = bound(p1, 1, 1e12);
        d0 = uint8(bound(d0, 0, 18));
        d1 = uint8(bound(d1, 0, 18));
        (uint256 s, uint256 c) = abi.decode(_reference("clOracleSqrt", _args(p0, p1, d0, d1)), (uint256, uint256));
        (uint160 gotS, bool gotC) = m.oracleSqrtPrice(p0, p1, d0, d1);
        assertEq(gotS, s);
        assertEq(gotC, c == 1);
    }

    // TEST-037 verifies: SPEC-ORC-009, REQ-ORACLE-012
    // Sources: MATH-UO-11b, MATH-UO-11f (all three branches of SPEC-ORC-009, prices up to the library bound 2^128 - 1)
    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_TEST_037_oracleSqrtPriceMatchesReferenceOverTheLibraryBounds(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public {
        p0 = bound(p0, 1, type(uint128).max);
        p1 = bound(p1, 1, type(uint128).max);
        d0 = uint8(bound(d0, 0, 18));
        d1 = uint8(bound(d1, 0, 18));
        (uint256 s, uint256 c) = abi.decode(_reference("clOracleSqrt", _args(p0, p1, d0, d1)), (uint256, uint256));
        (uint160 gotS, bool gotC) = m.oracleSqrtPrice(p0, p1, d0, d1);
        assertEq(gotS, s);
        assertEq(gotC, c == 1);
    }

    // TEST-037 verifies: SPEC-AMM-V3-001, SPEC-ORC-006, SPEC-AMM-CORE-001
    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_TEST_037_compositionMatchesReference(
        uint256 p0,
        uint256 p1,
        int24 lowerSeed,
        uint16 width,
        uint256 units
    ) public {
        p0 = bound(p0, 1e6, 1e10);
        p1 = bound(p1, 1e6, 1e10);
        int24 lower = int24(bound(int256(lowerSeed), -887_000, 880_000));
        int24 upper = lower + int24(uint24(bound(width, 1, 5000)));
        units = bound(units, 0, 2 ** 120);
        uint256[] memory args = new uint256[](7);
        (args[0], args[1], args[2], args[3]) = (p0, p1, 6, 18);
        args[4] = uint256(int256(lower) + int256(OFFSET));
        args[5] = uint256(int256(upper) + int256(OFFSET));
        args[6] = units;
        (uint256 e0, uint256 e1) = abi.decode(_reference("clComposition", args), (uint256, uint256));
        (uint160 s,) = m.oracleSqrtPrice(p0, p1, 6, 18);
        uint160 sa = m.sqrtRatioAtTick(lower);
        uint160 sb = m.sqrtRatioAtTick(upper);
        (uint256 a0, uint256 a1) = m.amountsForLiquidity(m.clamp(s, sa, sb), sa, sb, units);
        assertEq(a0 == 0 ? 0 : a0 - 1, e0, "token0");
        assertEq(a1 == 0 ? 0 : a1 - 1, e1, "token1");
    }
}
