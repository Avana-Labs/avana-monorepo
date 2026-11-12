// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleCombinedProbeUnitTest
/// @notice The combined USDT issuer probe (`UsdtFeeRateAndPaused`) on a debt asset: each of its two reads trips the
/// `ISSUER` condition exactly as the single kind with that read does, including a revert or a malformed answer.
contract RiskModuleCombinedProbeUnitTest is RiskModuleFixture {
    bytes4 internal constant PAUSED = bytes4(keccak256("paused()"));
    bytes4 internal constant FEE_RATE = bytes4(keccak256("basisPointsRate()"));

    /// @dev GHO is listed with the combined probe in this suite (both reads clear at listing).
    function _ghoIssuerProbe() internal pure override returns (IssuerProbe) {
        return IssuerProbe.UsdtFeeRateAndPaused;
    }

    function setUp() public {
        _deployRiskWorld();
        _debt(1.5e18, 1000);
    }

    function _debtReasons() internal view returns (uint32) {
        return riskModule.liveDebtBreakerReasons(address(spoke), GHO_RESERVE);
    }

    // TEST-228 verifies: SPEC-BRK-003, REQ-MREG-027, REQ-RISK-065
    // Sources: Launch configuration decision 2026-11-11 (USDT probe)
    /// @notice A pause trips the debt breaker and blocks a borrow; the fee read alone would miss it. Fails if the
    /// combined kind reads only `basisPointsRate()`.
    function test_TEST_228_combinedProbeTripsOnPause() public {
        assertEq(uint8(registry.getToken(address(gho)).issuerProbe), uint8(IssuerProbe.UsdtFeeRateAndPaused));
        assertEq(_debtReasons(), 0);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        tGho.setPaused(true, false);
        assertEq(_debtReasons(), BreakerReasons.ISSUER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtBreakerTripped.selector, address(spoke), GHO_RESERVE, BreakerReasons.ISSUER
            )
        );
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        tGho.setPaused(false, false);
        assertEq(_debtReasons(), 0);
        // A reverting pause read trips, as it does for `PausedFlag`.
        tGho.setPaused(false, true);
        assertEq(_debtReasons(), BreakerReasons.ISSUER);
    }

    // TEST-228 verifies: SPEC-BRK-003, REQ-MREG-027, REQ-SWAP-123, ATTACK-197
    // Sources: Launch configuration decision 2026-11-11 (USDT probe)
    /// @notice A fee switched on trips the debt breaker while the pause flag is clear. Fails if the combined kind
    /// reads only `paused()`.
    function test_TEST_228_combinedProbeTripsOnFee() public {
        tGho.setFee(10, false);
        assertEq(_debtReasons(), BreakerReasons.ISSUER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtBreakerTripped.selector, address(spoke), GHO_RESERVE, BreakerReasons.ISSUER
            )
        );
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        tGho.setFee(0, false);
        assertEq(_debtReasons(), 0);
        // Both tripped at once report the one `ISSUER` reason.
        tGho.setFee(10, false);
        tGho.setPaused(true, false);
        assertEq(_debtReasons(), BreakerReasons.ISSUER);
    }

    // TEST-228 verifies: SPEC-BRK-003, REQ-RISK-089
    /// @notice Each read fails closed on its own: a reverting fee read, a fee read with no return data and a pause
    /// read with no return data each trip while the other read is clear.
    function test_TEST_228_combinedProbeFailsClosedOnEitherRead() public {
        vm.mockCallRevert(address(tGho), abi.encodePacked(FEE_RATE), "rate");
        assertEq(_debtReasons(), BreakerReasons.ISSUER);
        vm.clearMockedCalls();
        assertEq(_debtReasons(), 0);
        vm.mockCall(address(tGho), abi.encodePacked(FEE_RATE), "");
        assertEq(_debtReasons(), BreakerReasons.ISSUER);
        vm.clearMockedCalls();
        vm.mockCall(address(tGho), abi.encodePacked(PAUSED), "");
        assertEq(_debtReasons(), BreakerReasons.ISSUER);
        vm.clearMockedCalls();
        assertEq(_debtReasons(), 0);
    }

    // TEST-228 verifies: SPEC-BRK-003, SPEC-BRK-008, REQ-RISK-091, INV-081
    /// @notice The latch of a combined-probe trip holds after the read clears, as for a single kind.
    function test_TEST_228_combinedProbeLatchesUntilReset() public {
        tGho.setPaused(true, false);
        riskModule.pokeBreakers(mid);
        (uint32 latched,) = registry.debtBreaker(address(spoke), GHO_RESERVE);
        assertEq(latched, BreakerReasons.ISSUER);
        tGho.setPaused(false, false);
        assertEq(_debtReasons(), 0);
        (uint32 reasons,) = riskModule.getDebtBreakerStatus(address(spoke), GHO_RESERVE);
        assertEq(reasons, BreakerReasons.ISSUER);
        // GHO is not a pool token of the market, so the market breaker stays clear.
        assertEq(riskModule.liveBreakerReasons(mid), 0);
    }
}
