// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DynamicCapMath} from "../../src/legacy/risk-module/DynamicCapMath.sol";
import {MarketDynamicCap} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";

/// @title DynamicCapMathUnitTest
/// @notice The buffer `L = clamp(alpha * D, L_min, L_max)`, the target cap `C = D + L`, the interval rollover and a
/// borrow's USD amount, on the library itself.
contract DynamicCapMathUnitTest is AvanaTest {
    uint256 internal constant E8 = 1e8;

    function _t() internal pure returns (MarketDynamicCap memory) {
        return MarketDynamicCap(21_600, 2500, uint96(250_000 * E8), uint96(2_500_000 * E8));
    }

    function test_bufferIsAlphaOfDebtBetweenTheBounds() public pure {
        assertEq(DynamicCapMath.buffer(_t(), 4_000_000 * E8), 1_000_000 * E8, "25 % of $4,000,000");
        assertEq(DynamicCapMath.buffer(_t(), 3_400_000 * E8), 850_000 * E8, "25 % of $3,400,000");
    }

    function test_bufferClampsAtLMin() public pure {
        assertEq(DynamicCapMath.buffer(_t(), 0), 250_000 * E8, "no debt: L_min");
        assertEq(DynamicCapMath.buffer(_t(), 1_000_000 * E8 - 1), 250_000 * E8, "25 % just below L_min");
        assertEq(DynamicCapMath.buffer(_t(), 1_000_000 * E8), 250_000 * E8, "25 % exactly L_min");
        assertEq(DynamicCapMath.buffer(_t(), 1_000_000 * E8 + 4), 250_000 * E8 + 1, "just above L_min");
    }

    function test_bufferClampsAtLMax() public pure {
        assertEq(DynamicCapMath.buffer(_t(), 10_000_000 * E8), 2_500_000 * E8, "25 % exactly L_max");
        assertEq(DynamicCapMath.buffer(_t(), 10_000_000 * E8 + 4), 2_500_000 * E8, "just above L_max");
        assertEq(DynamicCapMath.buffer(_t(), 1e30), 2_500_000 * E8, "huge debt: L_max");
    }

    function test_bufferRoundsDown() public pure {
        MarketDynamicCap memory t = MarketDynamicCap(3600, 1, 0, type(uint96).max);
        assertEq(DynamicCapMath.buffer(t, 9999), 0, "0.9999 rounds to 0");
        assertEq(DynamicCapMath.buffer(t, 19_999), 1, "1.9999 rounds to 1");
    }

    function test_neverWrittenTermsGiveBufferZero() public pure {
        MarketDynamicCap memory zero;
        assertEq(DynamicCapMath.buffer(zero, 1_000_000 * E8), 0);
        assertEq(DynamicCapMath.target(zero, 1_000_000 * E8), 1_000_000 * E8, "cap equals the debt");
    }

    function test_targetIsDebtPlusBuffer() public pure {
        assertEq(DynamicCapMath.target(_t(), 4_000_000 * E8), 5_000_000 * E8);
        assertEq(DynamicCapMath.target(_t(), 0), 250_000 * E8);
        assertEq(DynamicCapMath.target(_t(), 20_000_000 * E8), 22_500_000 * E8);
    }

    function test_targetSaturates() public pure {
        assertEq(DynamicCapMath.target(_t(), type(uint192).max), type(uint192).max);
        assertEq(DynamicCapMath.target(_t(), type(uint256).max / 10_000), type(uint192).max);
    }

    function test_intervalOpensAtTauExactly() public pure {
        assertFalse(DynamicCapMath.opensInterval(1000, 21_600, 1000 + 21_600 - 1));
        assertTrue(DynamicCapMath.opensInterval(1000, 21_600, 1000 + 21_600));
        assertTrue(DynamicCapMath.opensInterval(0, 21_600, 1_762_650_000), "an empty record opens one");
    }

    function test_usdOfRoundsUp() public pure {
        assertEq(DynamicCapMath.usdOf(250_026e6, 99_990_000, 6), 25_000_099_740_000, "250,026 USDC at $0.9999");
        assertEq(DynamicCapMath.usdOf(1, 99_990_000, 6), 100, "99.99 rounds up to 100");
        assertEq(DynamicCapMath.usdOf(1, 1, 18), 1, "a wei at 1e-8 dollars rounds up to one unit");
        assertEq(DynamicCapMath.usdOf(0, 1e8, 18), 0);
        assertEq(DynamicCapMath.usdOf(1e18, 1e8, 18), 1e8);
    }
}
