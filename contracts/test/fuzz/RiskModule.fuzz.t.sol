// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskModuleMath} from "../../src/policy/risk-module/RiskModuleMath.sol";
import {RiskModuleMathHarness} from "../utils/harness/RiskModuleMathHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @title RiskModuleFuzzTest
/// @notice Stateless properties of the RiskModule formulas: rounding direction, overflow inside listing bounds, the cap
/// split, the pool-share test, the peg product, the rescue exclusion and the exemption step.
contract RiskModuleFuzzTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    RiskModuleMathHarness internal h;

    function setUp() public {
        h = new RiskModuleMathHarness();
    }

    function _d(
        uint256 seed
    ) internal pure returns (uint8) {
        return uint8(seed % 19);
    }

    // TEST-071 verifies: SPEC-CAP-001, REQ-RISK-057
    // TEST-070 verifies: SPEC-CAP-001, REQ-RISK-021
    function testFuzz_TEST_071_chargeAndValueBounds(
        uint128 units,
        uint64 price8,
        uint64 floorUsd,
        uint256 dSeed
    ) public view {
        uint8 d = _d(dSeed);
        uint256 scale = 10 ** uint256(d);
        uint256 value = h.pledgeUsd(units, price8, d);
        uint256 charge = h.usdCharge(units, price8, floorUsd, d);
        uint256 p = price8 > floorUsd ? price8 : floorUsd;
        // Value floors, charge ceils, both exactly.
        assertLe(value * scale, uint256(units) * price8);
        assertGt((value + 1) * scale, uint256(units) * price8);
        assertGe(charge * scale, uint256(units) * p);
        if (charge > 0) assertLt((charge - 1) * scale, uint256(units) * p);
        assertGe(charge, value);
        if (units > 0 && p > 0) assertGe(charge, 1);
    }

    // TEST-013 verifies: SPEC-CAP-002, REQ-RISK-022
    function testFuzz_TEST_013_splitKeepsRegularWithinRoom(
        uint128 c,
        uint128 regular,
        uint128 cap,
        bool eligible
    ) public view {
        (uint256 slice, bool ok) = h.split(c, regular, cap, eligible);
        uint256 room = cap > regular ? cap - regular : 0;
        assertLe(slice, c);
        if (!eligible) {
            assertEq(slice, 0);
            assertEq(ok, c <= room);
        } else {
            assertTrue(ok);
            assertLe(c - slice, room);
            if (c <= room) assertEq(slice, 0);
        }
    }

    // TEST-013 verifies: SPEC-CAP-003, HYP-55
    function testFuzz_TEST_013_restoreRoundsUp(
        uint64 hfSeed,
        uint192 debtRay,
        uint16 cfSeed,
        uint64 price8,
        uint64 served8
    ) public view {
        uint256 hf = 1e18 + (uint256(hfSeed) % 1e17);
        uint256 cf = 1 + (uint256(cfSeed) % 9999);
        uint256 usd = h.usdToRestore(hf, debtRay, cf);
        if (hf >= 1.1e18 || debtRay == 0) {
            assertEq(usd, 0);
            return;
        }
        // usd * cf * 1e18 * WAD * RAY / 1e4 >= (1.10 - hf) * D: never below the exact amount.
        assertGe(usd * cf * 1e18 * (WAD * RAY / 1e4), (1.1e18 - hf) * uint256(debtRay));
        vm.assume(served8 > 0 && price8 > 0);
        uint256 booked = h.restoreBooked(usd, price8, 1e8, served8);
        uint256 p = price8 > 1e8 ? price8 : 1e8;
        assertGe(booked * served8, usd * p);
    }

    // TEST-077 verifies: SPEC-CF-005, REQ-RISK-068, INV-082
    function testFuzz_TEST_077_rescueExclusionNeverOverstates(
        uint64 hf,
        uint120 units,
        uint64 price8,
        uint16 cfSeed,
        uint256 debtSeed,
        uint256 dSeed
    ) public view {
        uint8 d = _d(dSeed) < 6 ? 6 : _d(dSeed);
        uint256 cf = uint256(cfSeed) % 10_001;
        uint256 debtRay = bound(debtSeed, 1e45, 2 ** 190);
        uint256 e = h.rescueValue(units, price8, cf, d);
        _checkValue(e, units, price8, cf, d);
        uint256 hfEx = h.healthExcludingRescue(hf, e, debtRay);
        assertLe(hfEx, hf);
        if (hfEx > 0) {
            // hf - hfEx >= E * WAD * RAY / D exactly: the exclusion is never smaller than the exact value.
            uint256 q = Math.mulDiv(e, WAD * RAY, debtRay);
            assertGe(uint256(hf) - hfEx, q);
            if (uint256(hf) - hfEx == q) assertEq(mulmod(e, WAD * RAY, debtRay), 0);
        }
    }

    /// @dev E rounds up: E >= u * p * cf * 1e18 / (10^d * 1e4), exactly.
    function _checkValue(
        uint256 e,
        uint256 units,
        uint256 price8,
        uint256 cf,
        uint8 d
    ) internal pure {
        uint256 num = price8 * cf * 1e18;
        uint256 den = 10 ** uint256(d) * 1e4;
        uint256 floorE = Math.mulDiv(units, num, den);
        assertGe(e, floorE);
        if (e == floorE) assertEq(mulmod(units, num, den), 0);
    }

    // TEST-236 verifies: REQ-RISK-059, REQ-RISK-068, SPEC-CF-005
    function testFuzz_TEST_236_requiredIsTheMaximum(
        uint256 floor_,
        uint256 minHf
    ) public view {
        uint256 r = h.requiredHealthFactor(floor_, minHf);
        assertGe(r, 1e18);
        assertGe(r, floor_);
        assertGe(r, minHf);
        assertTrue(r == 1e18 || r == floor_ || r == minHf);
    }

    // TEST-034 verifies: SPEC-CAP-005, REQ-RISK-023
    function testFuzz_TEST_034_poolShareExact(
        uint128 units,
        uint16 cap,
        uint128 depth
    ) public view {
        assertEq(h.poolShareExceeds(units, cap, depth), uint256(units) * 1e4 > uint256(cap) * depth);
    }

    // TEST-228 verifies: SPEC-BRK-002
    function testFuzz_TEST_228_pegProductExact(
        uint40 q0,
        uint40 q1,
        uint40 q2
    ) public view {
        uint256[] memory q = new uint256[](3);
        (q[0], q[1], q[2]) = (q0, q1, q2);
        bool exact = uint256(q0) * q1 * q2 <= 1e24;
        assertEq(h.atOrBelowPeg(q), exact);
    }

    // TEST-235 verifies: REQ-RISK-066, REQ-RISK-067, REQ-RISK-074, PROP-062
    function testFuzz_TEST_235_exemptionOutcome(
        RiskModuleMath.Exemption memory x
    ) public view {
        RiskModuleMath.Outcome o = h.exemption(x);
        bool needs = x.requireRescue || x.capFail || x.depthUnavailable || x.brk != 0 || x.belowMinimum;
        if (!needs) {
            assertEq(uint8(o), uint8(RiskModuleMath.Outcome.Pass));
            return;
        }
        if (o == RiskModuleMath.Outcome.Rescue) {
            assertTrue(x.eligible && x.charge <= x.restore);
            return;
        }
        assertFalse(x.eligible && x.charge <= x.restore);
        assertTrue(o != RiskModuleMath.Outcome.Pass);
        // A non-rescue pass never leaves the value below the minimum.
        if (x.belowMinimum) {
            assertTrue(o == RiskModuleMath.Outcome.BelowMinimum || o == RiskModuleMath.Outcome.NotRescue);
        }
        if (x.requireRescue) assertEq(uint8(o), uint8(RiskModuleMath.Outcome.NotRescue));
    }

    // TEST-196 verifies: REQ-RISK-057, REQ-RISK-067, PROP-062
    function testFuzz_TEST_196_rescueMinimum(
        uint256 minPledge
    ) public view {
        uint256 r = h.rescueMinimum(minPledge);
        assertLe(r, 10e8);
        assertLe(r, minPledge);
        assertTrue(r == 10e8 || r == minPledge);
    }

    // TEST-125 verifies: SPEC-CAP-006, PROP-030
    function testFuzz_TEST_125_budgetFitsAddCap(
        uint120 u1,
        uint120 u2,
        uint64 p1,
        uint64 p2,
        uint64 floorSeed,
        uint256 dSeed
    ) public view {
        uint8 d = _d(dSeed);
        uint256 floorUsd = 1 + uint256(floorSeed) % 1e12;
        uint256 c1 = h.usdCharge(u1, p1, floorUsd, d);
        uint256 c2 = h.usdCharge(u2, p2, floorUsd, d);
        // A budget of exactly c1 + c2 and an addCap of ceil(budget / floor) whole tokens holds both pledges.
        uint256 addCap = (c1 + c2 + floorUsd - 1) / floorUsd;
        assertLe(uint256(u1) + u2, addCap * 10 ** uint256(d));
    }

    // TEST-249 verifies: SPEC-CF-002, REQ-RISK-069
    function testFuzz_TEST_249_bonusBound(
        uint32 maxLb,
        uint16 cf,
        uint16 factor,
        uint16 minBonus
    ) public view {
        bool v = h.bonusBoundViolated(maxLb, cf, factor, minBonus);
        if (maxLb < 1e4) {
            assertTrue(v);
            return;
        }
        bool exact = (uint256(maxLb) * cf + 9999) / 1e4 >= 1e4 || (uint256(maxLb) - 1e4) * factor / 1e4 < minBonus;
        assertEq(v, exact);
    }

    // TEST-071 verifies: SPEC-CAP-005, REQ-RISK-023
    function testFuzz_TEST_071_poolShareUnitsOverflowFails(
        uint256 units,
        uint256 capBps,
        uint256 depth
    ) public view {
        // Avana's side `units x 1e4` does not fit 256 bits: the cap fails whatever the pool side.
        units = bound(units, type(uint256).max / 1e4 + 1, type(uint256).max);
        assertTrue(h.poolShareExceeds(units, capBps, depth));
    }

    // TEST-071 verifies: SPEC-CAP-005, REQ-RISK-023
    function testFuzz_TEST_071_poolShareDepthOverflowHolds(
        uint256 units,
        uint256 capBps,
        uint256 depth
    ) public view {
        // The pool side `capBps x depth` exceeds 2^256 while Avana's side fits: the cap holds.
        units = bound(units, 0, type(uint256).max / 1e4);
        capBps = bound(capBps, 2, type(uint256).max);
        depth = bound(depth, type(uint256).max / capBps + 1, type(uint256).max);
        assertFalse(h.poolShareExceeds(units, capBps, depth));
    }

    // TEST-071 verifies: SPEC-CF-005, REQ-RISK-068
    function testFuzz_TEST_071_rescueValueSaturates(
        uint256 units,
        uint256 price8,
        uint256 cfBps,
        uint256 dSeed
    ) public view {
        uint8 d = _d(dSeed);
        units = bound(units, 1, type(uint256).max);
        // A price of 2^128 or more, or a factor above 1e4, saturates E.
        uint256 bigPrice = bound(price8, 2 ** 128, type(uint256).max);
        uint256 cf = bound(cfBps, 1, 1e4);
        assertEq(h.rescueValue(units, bigPrice, cf, d), type(uint256).max);
        uint256 p = bound(price8, 1, 2 ** 128 - 1);
        uint256 bigCf = bound(cfBps, 1e4 + 1, type(uint256).max);
        assertEq(h.rescueValue(units, p, bigCf, d), type(uint256).max);
        // A saturated E excludes every health factor below 1e27 WAD on any debt.
        assertEq(h.healthExcludingRescue(1e27 - 1, type(uint256).max, bound(units, 1, type(uint256).max)), 0);
    }

    // TEST-077 verifies: SPEC-CF-005, REQ-RISK-068, INV-082
    function testFuzz_TEST_077_exclusionOnDebtBelowOneUnit(
        uint256 hf,
        uint256 e,
        uint256 debtRay
    ) public view {
        // D below WAD x RAY (debt under 1e-8 USD): hf - ceil(E x WAD x RAY / D), saturating at 0.
        debtRay = bound(debtRay, 1, WAD * RAY - 1);
        e = bound(e, 1, type(uint256).max / (WAD * RAY));
        uint256 sub = Math.ceilDiv(e * WAD * RAY, debtRay);
        assertEq(h.healthExcludingRescue(hf, e, debtRay), hf > sub ? hf - sub : 0);
    }

    // TEST-071 verifies: SPEC-CF-005, REQ-RISK-068
    function testFuzz_TEST_071_exclusionProductOverflowIsZero(
        uint256 hf,
        uint256 e,
        uint256 debtRay
    ) public view {
        // E x WAD x RAY does not fit 256 bits on a debt below WAD x RAY: the exclusion is above 2^256 / 1e45, more
        // than any health factor up to 1e30 (a 1e12 health factor), so hfEx is 0.
        debtRay = bound(debtRay, 1, WAD * RAY - 1);
        e = bound(e, type(uint256).max / (WAD * RAY) + 1, type(uint256).max);
        hf = bound(hf, 0, 1e30);
        assertEq(h.healthExcludingRescue(hf, e, debtRay), 0);
    }

    // TEST-013 verifies: SPEC-CAP-003, REQ-RISK-026
    function testFuzz_TEST_013_servedZeroReadsAsOne(
        uint128 usd,
        uint64 price8,
        uint64 floorUsd
    ) public view {
        uint256 p = price8 > floorUsd ? price8 : floorUsd;
        assertEq(h.restoreBooked(usd, price8, floorUsd, 0), uint256(usd) * p);
        assertEq(h.restoreBooked(usd, price8, floorUsd, 1), uint256(usd) * p);
    }
}
