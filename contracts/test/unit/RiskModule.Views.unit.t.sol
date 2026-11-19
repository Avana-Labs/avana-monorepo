// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleErrors} from "../../src/legacy/risk-module/IRiskModuleErrors.sol";
import {PledgeCounters, PledgePreview} from "../../src/types/PositionTypes.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleViewsUnitTest
/// @notice The non-reverting views: breaker status of a failed evaluation, the preview's remaining room of every cap,
/// the integration's errors in the preview, the served-price floor of the rescue exclusion and the restore amount of
/// an account without debt.
contract RiskModuleViewsUnitTest is RiskModuleFixture {
    bytes32 internal constant KEY = bytes32(uint256(7));

    function setUp() public {
        _deployRiskWorld();
        rVault.setPosition(KEY, wallet, 10_000e18);
    }

    // TEST-228 verifies: REQ-RISK-065, SPEC-BRK-007, SPEC-BRK-008, REQ-MREG-025
    function test_TEST_228_failedEvaluationReportsEveryReason() public view {
        // Market 999 has no record, so its integration cannot be read; debt reserve 99 has no definition.
        assertEq(riskModule.getBreakerStatus(999), BreakerReasons.MARKET);
        assertEq(riskModule.getDebtBreakerStatus(address(spoke), 99), BreakerReasons.DEBT);
        // The listed market and debt reserve evaluate normally.
        assertEq(riskModule.getBreakerStatus(mid), 0);
        assertEq(riskModule.getDebtBreakerStatus(address(spoke), GHO_RESERVE), 0);
    }

    // TEST-034 verifies: REQ-RISK-031, SPEC-CAP-002
    function test_TEST_034_previewRoomsFloorAtZero() public {
        PledgeCounters memory k = _counters();
        k.regularUsed = 1_000_001e8; // above the $1,000,000 market cap
        k.sliceUsed = 100_000e8; // the whole slice
        k.tokenUsed[0] = 10_000_000e8;
        k.tokenUsed[1] = 9_000_000e8;
        coll.setCounters(k);
        PledgePreview memory p = riskModule.previewPledge(wallet, mid, KEY);
        assertEq(p.marketRoomUsd, 0);
        assertEq(p.sliceRoomUsd, 0);
        assertEq(p.tokenRoomUsd[0], 0);
        assertEq(p.tokenRoomUsd[1], 1_000_000e8);
        assertFalse(p.eligible);
        assertEq(p.reason, IRiskModuleErrors.CapExceeded.selector);
        assertEq(p.usdCharge, 20_000e8);
    }

    // TEST-034 verifies: REQ-RISK-031, SPEC-CAP-002
    function test_TEST_034_previewTokenRoomWithoutCounters() public {
        // Counters without per-token entries: every token's room is its whole cap, and the pledge fails its token cap.
        PledgeCounters memory k = _counters();
        k.tokenUsed = new uint256[](0);
        coll.setCounters(k);
        PledgePreview memory p = riskModule.previewPledge(wallet, mid, KEY);
        assertEq(p.tokenRoomUsd.length, 2);
        assertEq(p.tokenRoomUsd[0], 10_000_000e8);
        assertEq(p.tokenRoomUsd[1], 10_000_000e8);
        assertFalse(p.eligible);
        assertEq(p.reason, IRiskModuleErrors.CapExceeded.selector);
    }

    // TEST-034 verifies: REQ-RISK-031, REQ-RISK-010, REQ-RISK-011
    function test_TEST_034_previewIntegrationRevertWithoutSelector() public {
        coll.setCounters(_counters());
        rVault.setValidateRevertsEmpty(true);
        PledgePreview memory p = riskModule.previewPledge(wallet, mid, KEY);
        assertFalse(p.eligible);
        assertEq(p.reason, IRiskModuleErrors.PoolMismatch.selector);
        assertEq(p.usdCharge, 0);
    }

    // TEST-236 verifies: SPEC-CF-005, REQ-RISK-068
    // Sources: 2.7 SPEC-CF-005 example (HF 1.2000, debt $10,000, 500 rescue tokens at CF 0.312)
    function test_TEST_236_servedPriceBelowOneReadsAsOne() public {
        _debt(1.2e18, 10_000);
        coll.setRescue(address(proxy), 500e18);
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (3120, 10_500);
        rSpoke.setDynamicAt(VT_RESERVE, 9, d);
        rSpoke.setUserKey(address(proxy), VT_RESERVE, 9);
        // At a served price of 1 (1e-8 USD): E = ceil(500e18 x 1 x 3,120 x 1e18 / 1e22) = 1.56e20, excluded
        // ceil(1.56e20 x 1e45 / 1e57) = 156,000,000 of health factor.
        oracle.setPrices(2e8, 0);
        assertEq(riskModule.postHealthCheck(address(proxy), 0), 1.2e18 - 156_000_000);
        oracle.setPrices(2e8, -5);
        assertEq(riskModule.postHealthCheck(address(proxy), 0), 1.2e18 - 156_000_000);
        oracle.setPrices(2e8, 1);
        assertEq(riskModule.postHealthCheck(address(proxy), 0), 1.2e18 - 156_000_000);
    }

    // TEST-013 verifies: SPEC-CAP-003
    function test_TEST_013_noDebtNothingToRestore() public {
        // No debt on any reserve: borrowCount 0.
        assertEq(riskModule.usdToRestore(address(proxy)), 0);
        _debt(1.02e18, 10_000);
        assertEq(riskModule.usdToRestore(address(proxy)), 266_666_666_667);
    }
}
