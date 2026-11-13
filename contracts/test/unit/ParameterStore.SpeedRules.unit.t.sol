// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ParameterStoreSpeedRules as R} from "../../src/policy/parameter-store/ParameterStoreSpeedRules.sol";
import {MarketSpeedLimits} from "../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../src/policy/parameter-store/types/SpeedLimit.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";

/// @title ParameterStoreSpeedRulesUnitTest
/// @notice The bounds and the field-by-field change directions of the speed limits (2.9 REQ-PSTORE-035,
/// REQ-PSTORE-036), on the library itself: each field's edge values, the window's reversed direction, the
/// never-written value as the tightest, and the comparison's symmetry.
contract ParameterStoreSpeedRulesUnitTest is AvanaTest {
    function _m() internal pure returns (MarketSpeedLimits memory) {
        return MarketSpeedLimits(21_600, 2500, 2500, 250_000e8, 2_500_000e8, 1_000_000e8, 10_000_000e8);
    }

    function _d() internal pure returns (SpeedLimit memory) {
        return SpeedLimit(2500, 21_600, 500_000e18, 5_000_000e18);
    }

    // TEST-325 verifies: REQ-PSTORE-035
    function test_TEST_325_rulesBoundsEdges() public pure {
        MarketSpeedLimits memory v = _m();
        assertTrue(R.validMarket(v));
        v.window = R.SPEED_WINDOW_MIN;
        assertTrue(R.validMarket(v), "3,600 s");
        v.window = R.SPEED_WINDOW_MIN - 1;
        assertFalse(R.validMarket(v), "3,599 s");
        v.window = R.SPEED_WINDOW_MAX;
        assertTrue(R.validMarket(v), "604,800 s");
        v.window = R.SPEED_WINDOW_MAX + 1;
        assertFalse(R.validMarket(v), "604,801 s");
        v = _m();
        v.window = 0;
        assertFalse(R.validMarket(v), "never-written window is not a valid write");
        v = _m();
        v.borrowRateBps = 10_000;
        v.pledgeRateBps = 10_000;
        assertTrue(R.validMarket(v));
        v.pledgeRateBps = 10_001;
        assertFalse(R.validMarket(v));
        v = _m();
        v.borrowRateBps = 10_001;
        assertFalse(R.validMarket(v));
        v = _m();
        v.borrowMinUsd = v.borrowMaxUsd;
        assertTrue(R.validMarket(v), "min == max");
        v.borrowMinUsd = v.borrowMaxUsd + 1;
        assertFalse(R.validMarket(v));
        v = _m();
        v.pledgeMinUsd = v.pledgeMaxUsd + 1;
        assertFalse(R.validMarket(v));
        v = _m();
        (v.borrowMinUsd, v.borrowMaxUsd, v.pledgeMinUsd, v.pledgeMaxUsd) = (type(uint96).max, type(uint96).max, 0, 0);
        assertTrue(R.validMarket(v), "uint96 bounds every amount");
    }

    // TEST-325 verifies: REQ-PSTORE-035
    function test_TEST_325_rulesDebtBoundsEdges() public pure {
        SpeedLimit memory d = _d();
        assertTrue(R.validDebt(d));
        d.rateBps = 10_001;
        assertFalse(R.validDebt(d));
        d = _d();
        d.window = 3599;
        assertFalse(R.validDebt(d));
        d.window = 604_801;
        assertFalse(R.validDebt(d));
        d = _d();
        d.min = d.max + 1;
        assertFalse(R.validDebt(d));
        d.min = d.max;
        assertTrue(R.validDebt(d));
        assertFalse(R.validDebt(SpeedLimit(0, 0, 0, 0)), "never written");
    }

    // TEST-325 verifies: REQ-PSTORE-036
    function test_TEST_325_rulesWindowDirectionIsReversed() public pure {
        MarketSpeedLimits memory longer = _m();
        longer.window += 1;
        (bool noLooser, bool stricter) = R.compareMarket(_m(), longer);
        assertTrue(noLooser && stricter, "a longer window is tighter");
        (noLooser, stricter) = R.compareMarket(longer, _m());
        assertFalse(noLooser, "a shorter window is looser");
        assertFalse(stricter);
        SpeedLimit memory d = _d();
        d.window += 1;
        (noLooser, stricter) = R.compareDebt(_d(), d);
        assertTrue(noLooser && stricter);
    }

    // TEST-325 verifies: REQ-PSTORE-036, REQ-RISK-096
    function test_TEST_325_rulesNeverWrittenIsTightest() public pure {
        MarketSpeedLimits memory zero;
        (bool noLooser, bool stricter) = R.compareMarket(_m(), zero);
        assertTrue(noLooser && stricter, "all zero is tighter than any written value");
        (noLooser,) = R.compareMarket(zero, _m());
        assertFalse(noLooser, "and any written value is looser than it");
        MarketSpeedLimits memory slowest = _m();
        slowest.window = R.SPEED_WINDOW_MAX;
        (slowest.borrowRateBps, slowest.pledgeRateBps) = (0, 0);
        (slowest.borrowMinUsd, slowest.borrowMaxUsd, slowest.pledgeMinUsd, slowest.pledgeMaxUsd) = (0, 0, 0, 0);
        (noLooser, stricter) = R.compareMarket(slowest, zero);
        assertTrue(noLooser && stricter, "even the slowest valid value is looser than never written");
        SpeedLimit memory dz;
        (noLooser, stricter) = R.compareDebt(_d(), dz);
        assertTrue(noLooser && stricter);
    }

    // TEST-325 verifies: REQ-PSTORE-036
    function test_TEST_325_rulesEachFieldCounts() public pure {
        MarketSpeedLimits memory a = _m();
        MarketSpeedLimits[6] memory lower;
        for (uint256 i = 0; i < 6; ++i) {
            lower[i] = _m();
        }
        lower[0].borrowRateBps -= 1;
        lower[1].pledgeRateBps -= 1;
        lower[2].borrowMinUsd -= 1;
        lower[3].borrowMaxUsd -= 1;
        lower[4].pledgeMinUsd -= 1;
        lower[5].pledgeMaxUsd -= 1;
        for (uint256 i = 0; i < 6; ++i) {
            (bool noLooser, bool stricter) = R.compareMarket(a, lower[i]);
            assertTrue(noLooser && stricter, "one field lower is a tightening");
            (noLooser, stricter) = R.compareMarket(lower[i], a);
            assertFalse(noLooser, "and the reverse a loosening");
            assertFalse(stricter);
        }
        (bool same1, bool strict1) = R.compareMarket(a, a);
        assertTrue(same1);
        assertFalse(strict1, "an equal value is neither");
    }

    // TEST-325 verifies: REQ-PSTORE-036
    function testFuzz_TEST_325_rulesCompareIsAntisymmetric(
        uint32 w1,
        uint16 r1,
        uint96 l1,
        uint96 h1,
        uint32 w2,
        uint16 r2,
        uint96 l2,
        uint96 h2
    ) public pure {
        SpeedLimit memory a = SpeedLimit(r1, w1, l1, h1);
        SpeedLimit memory b = SpeedLimit(r2, w2, l2, h2);
        (bool bNoLooser, bool bStricter) = R.compareDebt(a, b);
        (bool aNoLooser, bool aStricter) = R.compareDebt(b, a);
        // Some field of b tighter <=> some field of a looser, and the reverse.
        assertEq(bStricter, !aNoLooser, "b stricter somewhere iff a looser somewhere");
        assertEq(aStricter, !bNoLooser, "a stricter somewhere iff b looser somewhere");
        if (bNoLooser && bStricter) assertFalse(aNoLooser || aStricter, "a tightening reversed is a loosening");
        if (bNoLooser && aNoLooser) assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "equal both ways");
    }
}
