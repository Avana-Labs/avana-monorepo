// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ParameterStoreCapRules as R} from "../../src/policy/parameter-store/ParameterStoreCapRules.sol";
import {MarketDynamicCap} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";

/// @title ParameterStoreCapRulesUnitTest
/// @notice The bounds and the field-by-field change directions of the dynamic borrow cap terms, on the library
/// itself: each field's edge values, the interval's reversed direction, the never-written value as the tightest, and
/// the comparison's symmetry.
contract ParameterStoreCapRulesUnitTest is AvanaTest {
    function _t() internal pure returns (MarketDynamicCap memory) {
        return MarketDynamicCap(21_600, 2500, 250_000e8, 2_500_000e8);
    }

    function test_boundsEdges() public pure {
        MarketDynamicCap memory v = _t();
        assertTrue(R.valid(v));
        v.capInterval = R.CAP_INTERVAL_MIN;
        assertTrue(R.valid(v), "3,600 s");
        v.capInterval = R.CAP_INTERVAL_MIN - 1;
        assertFalse(R.valid(v), "3,599 s");
        v.capInterval = R.CAP_INTERVAL_MAX;
        assertTrue(R.valid(v), "604,800 s");
        v.capInterval = R.CAP_INTERVAL_MAX + 1;
        assertFalse(R.valid(v), "604,801 s");
        v = _t();
        v.capInterval = 0;
        assertFalse(R.valid(v), "never-written interval is not a valid write");
        v = _t();
        v.capAlphaBps = R.CAP_ALPHA_MAX;
        assertTrue(R.valid(v));
        v.capAlphaBps = R.CAP_ALPHA_MAX + 1;
        assertFalse(R.valid(v));
        v = _t();
        v.capBufferMin = v.capBufferMax;
        assertTrue(R.valid(v), "min == max");
        v.capBufferMin = v.capBufferMax + 1;
        assertFalse(R.valid(v));
        v = _t();
        (v.capBufferMin, v.capBufferMax) = (type(uint96).max, type(uint96).max);
        assertTrue(R.valid(v), "uint96 bounds every amount");
    }

    function test_neverWrittenIsTightest() public pure {
        MarketDynamicCap memory zero;
        (bool noLooser, bool stricter) = R.compare(_t(), zero);
        assertTrue(noLooser && stricter, "all zero is tighter than any written value");
        (noLooser,) = R.compare(zero, _t());
        assertFalse(noLooser, "and any written value is looser than it");
        MarketDynamicCap memory slowest = MarketDynamicCap(R.CAP_INTERVAL_MAX, 0, 0, 0);
        (noLooser, stricter) = R.compare(slowest, zero);
        assertTrue(noLooser && stricter, "even the longest valid interval is looser than never written");
    }

    function test_eachFieldCounts() public pure {
        MarketDynamicCap memory a = _t();
        MarketDynamicCap[3] memory lower;
        for (uint256 i = 0; i < 3; ++i) {
            lower[i] = _t();
        }
        lower[0].capAlphaBps -= 1;
        lower[1].capBufferMin -= 1;
        lower[2].capBufferMax -= 1;
        for (uint256 i = 0; i < 3; ++i) {
            (bool noLooser, bool stricter) = R.compare(a, lower[i]);
            assertTrue(noLooser && stricter, "one field lower is a tightening");
            (noLooser, stricter) = R.compare(lower[i], a);
            assertFalse(noLooser, "and the reverse a loosening");
            assertFalse(stricter);
        }
        (bool same, bool strict) = R.compare(a, a);
        assertTrue(same);
        assertFalse(strict, "an equal value is neither");
    }

    function testFuzz_compareIsAntisymmetric(
        uint32 i1,
        uint16 a1,
        uint96 l1,
        uint96 h1,
        uint32 i2,
        uint16 a2,
        uint96 l2,
        uint96 h2
    ) public pure {
        MarketDynamicCap memory a = MarketDynamicCap(i1, a1, l1, h1);
        MarketDynamicCap memory b = MarketDynamicCap(i2, a2, l2, h2);
        (bool bNoLooser, bool bStricter) = R.compare(a, b);
        (bool aNoLooser, bool aStricter) = R.compare(b, a);
        // Some field of b tighter <=> some field of a looser, and the reverse.
        assertEq(bStricter, !aNoLooser, "b stricter somewhere iff a looser somewhere");
        assertEq(aStricter, !bNoLooser, "a stricter somewhere iff b looser somewhere");
        if (bNoLooser && bStricter) assertFalse(aNoLooser || aStricter, "a tightening reversed is a loosening");
        if (bNoLooser && aNoLooser) assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "equal both ways");
    }

    /// @notice Interval looseness keeps every second apart up to the longest interval.
    function test_intervalOneSecondApartAtTheTop() public pure {
        MarketDynamicCap memory slow = _t();
        slow.capInterval = R.CAP_INTERVAL_MAX;
        MarketDynamicCap memory faster = _t();
        faster.capInterval = R.CAP_INTERVAL_MAX - 1;
        (bool noLooser, bool stricter) = R.compare(slow, faster);
        assertFalse(noLooser, "one second shorter is looser");
        (noLooser, stricter) = R.compare(faster, slow);
        assertTrue(noLooser && stricter, "one second longer is tighter");
    }
}
