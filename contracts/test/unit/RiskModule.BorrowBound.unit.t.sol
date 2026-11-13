// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {PledgePreview} from "../../src/types/PledgePreview.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RiskModuleMathHarness} from "../utils/harness/RiskModuleMathHarness.sol";

/// @title RiskModuleBorrowBoundUnitTest
/// @notice The accepted price bounds borrowing only (SPEC-ORC-017, REQ-RISK-026, REQ-RISK-059): after a borrow-side
/// action the health factor is checked at `min(served, accepted)`, so a rally the LPOracle has not accepted yet adds no
/// borrowing power, while a fall is used at once; a pledge is booked at `min(fresh, accepted)`.
contract RiskModuleBorrowBoundUnitTest is RiskModuleFixture {
    function setUp() public {
        _deployRiskWorld();
    }

    // TEST-230 verifies: REQ-RISK-059, REQ-RISK-026, SPEC-CF-005, SPEC-ORC-017
    /// @dev Served $2.20 after a rally, accepted $2.00: an Aave health factor of 1.05 is checked as
    /// `1.05 * 2.00 / 2.20 = 0.954545...`, below Aave's 1.00, so the borrow reverts.
    function test_TEST_230_rallyAddsNoBorrowingPower() public {
        _debt(1.05e18, 10_000);
        oracle.setPrices(2e8, 2.2e8);
        uint256 bounded = uint256(1.05e18) * 2e8 / 2.2e8;
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, bounded, 1e18));
        riskModule.postHealthCheck(address(proxy), 0);
        // At HF 1.20 the bounded value 1.0909 passes and is what the check returns.
        _debt(1.2e18, 10_000);
        assertEq(riskModule.postHealthCheck(address(proxy), 0), uint256(1.2e18) * 2e8 / 2.2e8);
    }

    // TEST-230 verifies: REQ-RISK-059, SPEC-ORC-017
    /// @dev A fall below the accepted price is used as Aave computes it: no scaling.
    function test_TEST_230_fallIsUsedAsIs() public {
        _debt(1.05e18, 10_000);
        oracle.setPrices(2e8, 1.8e8);
        assertEq(riskModule.postHealthCheck(address(proxy), 0), 1.05e18);
    }

    // TEST-230 verifies: REQ-RISK-026, SPEC-CAP-001
    /// @dev The pledge charge is booked at min(fresh, accepted): fresh $1.50 under accepted $2.00 books 10,000 units
    /// at $1.50 each.
    function test_TEST_230_pledgeBookedAtTheLowerOfFreshAndAccepted() public {
        bytes32 key = bytes32(uint256(7));
        rVault.setPosition(key, wallet, 10_000e18);
        PledgeCounters memory k = _counters();
        coll.setCounters(k);
        oracle.setFresh(1.5e8);
        PledgePreview memory p = riskModule.previewPledge(wallet, mid, key);
        assertTrue(p.eligible);
        assertEq(p.usdCharge, 15_000e8, "booked at the fresh price");
        // A fresh price above the accepted one books at the accepted price.
        oracle.setFresh(2.4e8);
        p = riskModule.previewPledge(wallet, mid, key);
        assertEq(p.usdCharge, 20_000e8, "booked at the accepted price");
        oracle.setState(PriceState.Live, 0, true);
    }

    // TEST-230 verifies: REQ-RISK-026, REQ-RISK-059
    function testFuzz_TEST_230_boundsNeverRaise(
        uint256 hf,
        uint256 served,
        uint256 accepted,
        uint256 fresh
    ) public {
        RiskModuleMathHarness h = new RiskModuleMathHarness();
        hf = bound(hf, 0, 1e40);
        served = bound(served, 0, 1e30);
        accepted = bound(accepted, 1, 1e30);
        fresh = bound(fresh, 0, 1e30);
        uint256 b = h.boundedHealthFactor(hf, served, accepted);
        assertLe(b, hf, "bounded above hf");
        if (served != 0 && accepted < served) assertEq(b, hf * accepted / served);
        else assertEq(b, hf);
        uint256 price = h.bookingPrice(accepted, fresh);
        assertLe(price, accepted, "booked above the accepted price");
        assertEq(price, fresh != 0 && fresh < accepted ? fresh : accepted);
    }
}
