// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {IRiskModuleErrors} from "../../src/legacy/risk-module/IRiskModuleErrors.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RiskModuleMathHarness} from "../utils/harness/RiskModuleMathHarness.sol";

/// @title RiskModuleBreakersUnitTest
/// @notice Live breaker conditions (issuer probe, Hub deficit, pool depth) on the borrow path, and the issuer-probe gas
/// floor.
contract RiskModuleBreakersUnitTest is RiskModuleFixture {
    /// @dev GHO is listed with a transfer-fee probe (basisPointsRate 0 at listing), for the transfer-fee breaker test.
    function _ghoIssuerProbe() internal pure override returns (IssuerProbe) {
        return IssuerProbe.UsdtFeeRate;
    }

    function setUp() public {
        _deployRiskWorld();
        _debt(1.5e18, 1000);
    }

    // TEST-228 verifies: SPEC-BRK-003, SPEC-BRK-008, REQ-RISK-091, INV-081
    // Sources: 2.7 SPEC-BRK-008 example (issuer action holds the market while the probe trips)
    function test_TEST_228_issuerHoldsWhileProbeTrips() public {
        tUsdt.setPaused(true, false);
        assertEq(riskModule.getBreakerStatus(mid), BreakerReasons.ISSUER);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.ISSUER));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        // The probe clears: the borrow passes in the same block, with no reset.
        tUsdt.setPaused(false, false);
        assertEq(riskModule.getBreakerStatus(mid), 0);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        // A reverting probe counts as tripped.
        tUsdt.setPaused(false, true);
        assertEq(riskModule.getBreakerStatus(mid), BreakerReasons.ISSUER);
    }

    // TEST-228 verifies: REQ-RISK-065, SPEC-BRK-007, REQ-ACCESS-136
    function test_TEST_228_depthGateAndPriceFreshness() public {
        rVault.setDepth(0, false);
        assertEq(riskModule.getBreakerStatus(mid), BreakerReasons.POOL_DEPTH);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.POOL_DEPTH)
        );
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        rVault.setDepth(2e13, true);
        assertEq(riskModule.getBreakerStatus(mid), 0);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        // A price that is not fresh to borrow is the freshness check's refusal, not a breaker reason.
        oracle.setState(PriceState.Drifting, 1 << 3, false);
        assertEq(riskModule.getBreakerStatus(mid), 0);
        vm.expectPartialRevert(IRiskModuleErrors.PriceTooOld.selector);
        riskModule.preWithdrawCheck(address(proxy));
        oracle.setState(PriceState.Live, 0, true);
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-228 verifies: SPEC-BRK-004, SPEC-BRK-008, REQ-RISK-091, INV-081, REQ-ACCESS-158, REQ-ACCESS-167, REQ-FLR-021
    // Sources: 2.7 SPEC-BRK-004 example (deficit 10,000.5 GHO above 10,000 GHO), 2.14 REQ-FLR-021 (the reserve
    // reopens once the deficit is at or below the limit)
    function test_TEST_228_deficitHoldsDebtReserve() public {
        store.setDeficitMax(address(hub), address(gho), 10_000e18);
        hub.setOwed(GHO_ASSET, address(spoke), 0, 10_000e18 * 1e27);
        assertEq(riskModule.getDebtBreakerStatus(address(spoke), GHO_RESERVE), 0);
        hub.setOwed(GHO_ASSET, address(spoke), 0, 10_000.5e18 * 1e27);
        assertEq(riskModule.getDebtBreakerStatus(address(spoke), GHO_RESERVE), BreakerReasons.DEFICIT);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtBreakerTripped.selector, address(spoke), GHO_RESERVE, BreakerReasons.DEFICIT
            )
        );
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        // Covered: the borrow passes in the same block, with no reset.
        hub.setOwed(GHO_ASSET, address(spoke), 0, 0);
        assertEq(riskModule.getDebtBreakerStatus(address(spoke), GHO_RESERVE), 0);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }

    // TEST-221 verifies: SPEC-BRK-003, REQ-RISK-089
    // Sources: 2.7 REQ-RISK-089 example (35,477 gas needed before a 30,000-gas probe)
    function test_TEST_221_probeGasFloor() public {
        RiskModuleMathHarness h = new RiskModuleMathHarness();
        assertEq(h.gasFloor(30_000), 35_477);
        (bool ok, uint256 len) = h.probe{gas: 100_000}(address(tUsdt), 30_000);
        assertTrue(ok);
        assertEq(len, 32);
        vm.expectPartialRevert(IRiskModuleErrors.InsufficientGas.selector);
        h.probe{gas: 34_000}(address(tUsdt), 30_000);
    }

    // TEST-228 verifies: SPEC-BRK-003, SPEC-BRK-004, SPEC-BRK-008, REQ-RISK-091, INV-081
    function test_TEST_228_issuerOfDebtAsset() public {
        _enableUsdcDebt();
        // USDC is listed with a `paused()` probe and is both a pool token and a debt asset.
        tUsdc.setPaused(true, false);
        assertEq(riskModule.getDebtBreakerStatus(address(spoke), USDC_RESERVE), BreakerReasons.ISSUER);
        assertEq(riskModule.getBreakerStatus(mid), BreakerReasons.ISSUER);
        // GHO, listed without a probe, is untouched.
        assertEq(riskModule.getDebtBreakerStatus(address(spoke), GHO_RESERVE), 0);
        // Once the probe clears, neither the debt reserve nor the market holds.
        tUsdc.setPaused(false, false);
        assertEq(riskModule.getDebtBreakerStatus(address(spoke), USDC_RESERVE), 0);
        assertEq(riskModule.getBreakerStatus(mid), 0);
    }

    // TEST-228 verifies: SPEC-BRK-003, REQ-RISK-065, ATTACK-197
    // Sources: 2.7 SPEC-BRK-003 example (basisPointsRate 0 at listing, then 10)
    function test_TEST_228_transferFeeTripsDebtBreaker() public {
        // GHO is listed with the `UsdtFeeRate` probe by this suite's `_ghoIssuerProbe`.
        assertEq(registry.getToken(address(gho)).issuerProbe == IssuerProbe.UsdtFeeRate, true);
        assertEq(riskModule.getDebtBreakerStatus(address(spoke), GHO_RESERVE), 0);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        tGho.setFee(10, false);
        assertEq(riskModule.getDebtBreakerStatus(address(spoke), GHO_RESERVE), BreakerReasons.ISSUER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtBreakerTripped.selector, address(spoke), GHO_RESERVE, BreakerReasons.ISSUER
            )
        );
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        // GHO is not a pool token of the market, so the market breaker stays clear.
        assertEq(riskModule.getBreakerStatus(mid), 0);
        // The fee is switched off: the borrow passes in the same block, with no reset.
        tGho.setFee(0, false);
        assertEq(riskModule.getDebtBreakerStatus(address(spoke), GHO_RESERVE), 0);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }
}
