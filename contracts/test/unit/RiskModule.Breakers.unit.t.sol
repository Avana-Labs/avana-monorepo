// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RiskModuleMathHarness} from "../utils/harness/RiskModuleMathHarness.sol";

/// @title RiskModuleBreakersUnitTest
/// @notice Breaker conditions, `pokeBreakers`, temporary-gate recovery, security latches and the issuer-probe gas floor.
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
    // Sources: 2.7 SPEC-BRK-008 example (issuer action, latched, reset only once the probe clears)
    function test_TEST_228_issuerLatchesUntilReset() public {
        tUsdt.setPaused(true, false);
        assertEq(riskModule.liveBreakerReasons(mid), BreakerReasons.ISSUER);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.ISSUER));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.expectEmit(address(riskModule));
        emit IRiskModuleChecks.BreakersPoked(mid, BreakerReasons.ISSUER);
        assertEq(riskModule.pokeBreakers(mid), BreakerReasons.ISSUER);
        // A reset is refused while the probe still trips.
        vm.prank(emergencyGuardian);
        vm.expectRevert();
        registry.resetMarketBreaker(mid);
        tUsdt.setPaused(false, false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.ISSUER));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.prank(emergencyGuardian);
        registry.resetMarketBreaker(mid);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        // A reverting probe counts as tripped.
        tUsdt.setPaused(false, true);
        assertEq(riskModule.liveBreakerReasons(mid), BreakerReasons.ISSUER);
    }

    // TEST-228 verifies: SPEC-BRK-002, SPEC-BRK-007, REQ-RISK-091, REQ-ACCESS-158, REQ-ACCESS-167, REQ-ACCESS-136, REQ-ACCESS-087
    // Sources: 2.7 SPEC-BRK-007 example (breached through t = 1,600 after start, reopens 1,800 s later)
    function test_TEST_228_poolShareGateRecovers() public {
        store.setPoolShare(poolKey, 1000);
        coll.setPoolUnits(poolKey, 2.1e12); // 2.1e16 > 1,000 x 2e13
        _report(uint64(block.timestamp), 97_000_000, 100_000_000);
        uint256 start = block.timestamp;
        assertEq(riskModule.pokeBreakers(mid), BreakerReasons.POOL_SHARE);
        vm.warp(start + 600);
        _report(uint64(block.timestamp), 97_000_000, 100_000_000);
        riskModule.pokeBreakers(mid);
        coll.setPoolUnits(poolKey, 2e12); // equality: not tripped
        vm.warp(start + 612);
        _report(uint64(block.timestamp), 97_000_000, 100_000_000);
        (uint32 reasons, uint64 reopensAt) = riskModule.getBreakerStatus(mid);
        assertEq(reopensAt, start + 600 + 1800);
        assertEq(reasons, BreakerReasons.TEMPORARY);
        vm.warp(start + 600 + 1799);
        _report(uint64(block.timestamp), 97_000_000, 100_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.TEMPORARY)
        );
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.warp(start + 600 + 1800);
        _report(uint64(block.timestamp), 97_000_000, 100_000_000);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        (reasons, reopensAt) = riskModule.getBreakerStatus(mid);
        assertEq(reasons, 0);
        assertEq(reopensAt, 0);
    }

    // TEST-228 verifies: SPEC-BRK-002
    // Sources: 2.7 SPEC-BRK-002 example (GHO at 1.046 keeps the product above peg)
    function test_TEST_228_premiumDoesNotTripConcentration() public {
        store.setPoolShare(poolKey, 1000);
        coll.setPoolUnits(poolKey, 2.12e12);
        rVault.setDepth(5.12e12, true);
        _report(uint64(block.timestamp), 104_600_000, 100_000_000);
        assertEq(riskModule.liveBreakerReasons(mid), 0);
        (uint32 reasons,) = riskModule.getBreakerStatus(mid);
        assertEq(reasons, 0);
        _report(uint64(block.timestamp), 99_000_000, 100_000_000);
        (reasons,) = riskModule.getBreakerStatus(mid);
        assertEq(reasons, BreakerReasons.POOL_SHARE);
    }

    // TEST-228 verifies: REQ-RISK-065, SPEC-BRK-007, REQ-ACCESS-136
    function test_TEST_228_depthAndOracleGates() public {
        rVault.setDepth(0, false);
        (uint32 reasons,) = riskModule.getBreakerStatus(mid);
        assertEq(reasons, BreakerReasons.POOL_DEPTH);
        rVault.setDepth(2e13, true);
        oracle.setState(PriceState.Drifting, 1 << 3, false);
        assertEq(riskModule.pokeBreakers(mid), BreakerReasons.ORACLE);
        // The oracle gate recovers 1,800 s after the last poke that saw it.
        oracle.setState(PriceState.Live, 0, true);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.TEMPORARY)
        );
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-228 verifies: SPEC-BRK-004, SPEC-BRK-008, REQ-RISK-091, INV-081, REQ-ACCESS-158, REQ-ACCESS-167
    // Sources: 2.7 SPEC-BRK-004 example (deficit 10,000.5 GHO above 10,000 GHO)
    function test_TEST_228_deficitFreezesDebtReserve() public {
        store.setDeficitMax(address(hub), address(gho), 10_000e18);
        hub.setOwed(GHO_ASSET, address(spoke), 0, 10_000e18 * 1e27);
        assertEq(riskModule.liveDebtBreakerReasons(address(spoke), GHO_RESERVE), 0);
        hub.setOwed(GHO_ASSET, address(spoke), 0, 10_000.5e18 * 1e27);
        assertEq(riskModule.liveDebtBreakerReasons(address(spoke), GHO_RESERVE), BreakerReasons.DEFICIT);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtBreakerTripped.selector, address(spoke), GHO_RESERVE, BreakerReasons.DEFICIT
            )
        );
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        assertEq(riskModule.pokeBreakers(mid), BreakerReasons.DEFICIT);
        // Covered: the latch keeps the reserve closed until reset.
        hub.setOwed(GHO_ASSET, address(spoke), 0, 0);
        (uint32 reasons,) = riskModule.getDebtBreakerStatus(address(spoke), GHO_RESERVE);
        assertEq(reasons, BreakerReasons.DEFICIT);
        vm.prank(emergencyGuardian);
        registry.resetDebtBreaker(address(spoke), GHO_RESERVE);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }

    // TEST-228 verifies: REQ-MREG-026, REQ-RISK-091, REQ-ACCESS-167
    function test_TEST_228_recordBreachOnlyRiskModule() public {
        vm.expectRevert(IMarketRegistryErrors.NotRiskModule.selector);
        registry.recordBreach(bytes32(mid), BreakerReasons.ISSUER);
        assertEq(riskModule.pokeBreakers(mid), 0);
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
        // A starved poke reverts as a whole and latches nothing.
        (ok,) = address(riskModule).call{gas: 300_000}(abi.encodeCall(riskModule.pokeBreakers, (mid)));
        assertFalse(ok);
        (uint32 latched,) = registry.marketBreaker(mid);
        assertEq(latched, 0);
    }

    // TEST-228 verifies: SPEC-BRK-003, SPEC-BRK-004, SPEC-BRK-008, REQ-RISK-091, INV-081
    function test_TEST_228_issuerOfDebtAsset() public {
        _enableUsdcDebt();
        // USDC is listed with a `paused()` probe and is both a pool token and a debt asset.
        tUsdc.setPaused(true, false);
        assertEq(riskModule.liveDebtBreakerReasons(address(spoke), USDC_RESERVE), BreakerReasons.ISSUER);
        (uint32 reasons, uint64 reopensAt) = riskModule.getDebtBreakerStatus(address(spoke), USDC_RESERVE);
        assertEq(reasons, BreakerReasons.ISSUER);
        assertEq(reopensAt, 0);
        // GHO, listed without a probe, is untouched.
        assertEq(riskModule.liveDebtBreakerReasons(address(spoke), GHO_RESERVE), 0);
        // The poke latches the market and the USDC debt reserve, not the GHO reserve.
        assertEq(riskModule.pokeBreakers(mid), BreakerReasons.ISSUER);
        (uint32 latched,) = registry.debtBreaker(address(spoke), USDC_RESERVE);
        assertEq(latched, BreakerReasons.ISSUER);
        (latched,) = registry.debtBreaker(address(spoke), GHO_RESERVE);
        assertEq(latched, 0);
        // Once the probe clears, the latch keeps the debt reserve closed until reset.
        tUsdc.setPaused(false, false);
        assertEq(riskModule.liveDebtBreakerReasons(address(spoke), USDC_RESERVE), 0);
        (reasons,) = riskModule.getDebtBreakerStatus(address(spoke), USDC_RESERVE);
        assertEq(reasons, BreakerReasons.ISSUER);
    }

    // TEST-228 verifies: SPEC-BRK-003, REQ-RISK-065, ATTACK-197
    // Sources: 2.7 SPEC-BRK-003 example (basisPointsRate 0 at listing, then 10)
    function test_TEST_228_transferFeeTripsDebtBreaker() public {
        // GHO is listed with the `UsdtFeeRate` probe by this suite's `_ghoIssuerProbe`.
        assertEq(registry.getToken(address(gho)).issuerProbe == IssuerProbe.UsdtFeeRate, true);
        assertEq(riskModule.liveDebtBreakerReasons(address(spoke), GHO_RESERVE), 0);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        tGho.setFee(10, false);
        assertEq(riskModule.liveDebtBreakerReasons(address(spoke), GHO_RESERVE), BreakerReasons.ISSUER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtBreakerTripped.selector, address(spoke), GHO_RESERVE, BreakerReasons.ISSUER
            )
        );
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        // GHO is not a pool token of the market, so the market breaker stays clear.
        assertEq(riskModule.liveBreakerReasons(mid), 0);
        tGho.setFee(0, false);
        assertEq(riskModule.liveDebtBreakerReasons(address(spoke), GHO_RESERVE), 0);
    }
}
