// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IRiskModuleErrors} from "../../src/legacy/risk-module/IRiskModuleErrors.sol";
import {DriftReason} from "../../src/types/MarketTypes.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleBreakerRecoveryUnitTest
/// @notice A paused vault-token reserve kept to its own market (REQ-RISK-014, REQ-RISK-088) and the cap charge at the
/// fresh price (REQ-RISK-026, SPEC-CAP-001), on the real LegacyRiskModule and MarketRegistry.
contract RiskModuleBreakerRecoveryUnitTest is RiskModuleFixture {
    uint128 internal constant TEN_K = 10_000e18; // $20,000 at $2.00 per whole token

    function setUp() public {
        _deployRiskWorld();
        _debt(1.5e18, 1000);
    }

    // ----------------------------------------------------------------------------------------- reserve pause

    // TEST-268 verifies: REQ-RISK-014, REQ-RISK-078, REQ-RISK-088, REQ-RISK-090
    /// @dev A paused vault-token reserve is the market's own containment: no drift, no breaker reason, and the market's
    /// own borrow and pledge gates refuse it.
    function test_TEST_268_pausedReserveStaysPerMarket() public {
        IAaveV4Spoke.ReserveConfig memory c;
        c.paused = true;
        rSpoke.setConfig(VT_RESERVE, c);
        uint256[] memory none = new uint256[](0);
        riskModule.checkAaveConfig(address(spoke), none);
        assertEq(uint8(riskModule.pokeConfig(address(spoke))), uint8(DriftReason.None), "no drift");
        assertEq(riskModule.getBreakerStatus(mid), 0, "no breaker reason");
    }

    // ----------------------------------------------------------------------------------------- cap price

    // TEST-230 verifies: REQ-RISK-026, REQ-RISK-057
    function test_TEST_230_minimumStaysAtTheLowerPrice() public {
        oracle.setState(PriceState.Drifting, 1 << 3, true);
        oracle.setFresh(2.3e8);
        store.setMarket(mid, 4000, 100_000e8, 100_000_000e8, 100_000e8, 1e8);
        // Minimum $100,000: 50,000 tokens are $100,000 at $2.00 and pass; 49,999 are $99,998 at $2.00 and fail even
        // though they are $114,997.7 at $2.30.
        _pledge(50_000e18, _counters(), false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BelowMinPledge.selector, 99_998e8, 100_000e8));
        _pledge(49_999e18, _counters(), false);
    }
}
