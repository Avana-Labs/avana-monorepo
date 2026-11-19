// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "../../src/legacy/risk-module/IRiskModuleErrors.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {PledgeCounters, PledgePreview} from "../../src/types/PositionTypes.sol";
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

    // TEST-230 verifies: REQ-RISK-059, SPEC-ORC-017
    /// @dev A fall below the accepted price is used as Aave computes it: no scaling.
    function test_TEST_230_fallIsUsedAsIs() public {
        _debt(1.05e18, 10_000);
        oracle.setPrices(2e8, 1.8e8);
        assertEq(riskModule.postHealthCheck(address(proxy), 0), 1.05e18);
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
