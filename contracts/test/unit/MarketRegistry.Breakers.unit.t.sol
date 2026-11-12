// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistrySafetyEvents} from "../../src/policy/market-registry/IMarketRegistrySafetyEvents.sol";
import {BreakerReasons, BreakerScope} from "../../src/policy/market-registry/types/Breaker.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";

/// @notice Breaker state of the MarketRegistry: breach records, manual trips and authorized resets.
contract MarketRegistryBreakersUnitTest is MarketRegistryFixture {
    uint256 internal marketId;
    bytes32 internal mKey;
    bytes32 internal dKey;

    function setUp() public {
        _setUpWorld();
        (marketId,,) = _activeMarket();
        mKey = bytes32(marketId);
        dKey = keccak256(abi.encode(address(spoke), GHO_RESERVE));
    }

    // TEST-228 verifies: REQ-MREG-026, REQ-MREG-025, SPEC-BRK-005, SPEC-BRK-006, Q-399
    // Sources: 5.1 TEST-228
    function test_TEST_228_recordBreachLatchesSecurityAndTimesTemporary() public {
        vm.warp(1000);
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.GateBreached(mKey, BreakerReasons.POOL_SHARE, 1000);
        vm.prank(address(rm));
        registry.recordBreach(mKey, BreakerReasons.POOL_SHARE);
        (uint32 latched, uint64 last) = registry.marketBreaker(marketId);
        assertEq(latched, 0);
        assertEq(last, 1000);
        assertEq(registry.lastBreachAt(mKey), 1000);

        vm.warp(2000);
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.BreakerLatched(BreakerScope.DebtReserve, dKey, BreakerReasons.DEFICIT);
        vm.prank(address(rm));
        registry.recordBreach(dKey, BreakerReasons.DEFICIT | BreakerReasons.MANUAL);
        (latched, last) = registry.debtBreaker(address(spoke), GHO_RESERVE);
        assertEq(latched, BreakerReasons.DEFICIT, "MANUAL from the RiskModule is ignored");
        assertEq(last, 0);
        // A repeat adds nothing and emits nothing.
        vm.recordLogs();
        vm.prank(address(rm));
        registry.recordBreach(dKey, BreakerReasons.DEFICIT);
        assertEq(vm.getRecordedLogs().length, 0);
        vm.prank(keeper);
        vm.expectRevert(IMarketRegistryErrors.NotRiskModule.selector);
        registry.recordBreach(mKey, BreakerReasons.ISSUER);
    }

    // TEST-228 verifies: REQ-MREG-025, Q-241, REQ-ACCESS-158, REQ-ACCESS-084, REQ-CONFIG-068
    function test_TEST_228_manualTripsAndUnknownKeys() public {
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.BreakerLatched(BreakerScope.Market, mKey, BreakerReasons.MANUAL);
        vm.prank(emergencyGuardian);
        registry.tripMarketBreaker(marketId);
        vm.prank(address(timelock));
        registry.tripDebtBreaker(address(spoke), GHO_RESERVE);
        (uint32 latched,) = registry.debtBreaker(address(spoke), GHO_RESERVE);
        assertEq(latched, BreakerReasons.MANUAL);
        vm.startPrank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 99));
        registry.tripMarketBreaker(99);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownDebtReserve.selector, address(spoke), 7));
        registry.tripDebtBreaker(address(spoke), 7);
        vm.stopPrank();
    }

    // TEST-228 verifies: REQ-MREG-025, SPEC-BRK-008, Q-241, Q-399, REQ-ACCESS-158, REQ-ACCESS-170
    function test_TEST_228_resetNeedsALatchAndAClearCondition() public {
        vm.prank(aaveGuardian);
        vm.expectRevert(IMarketRegistryErrors.NothingToReset.selector);
        registry.resetMarketBreaker(marketId);

        vm.warp(5000);
        vm.prank(address(rm));
        registry.recordBreach(mKey, BreakerReasons.ISSUER | BreakerReasons.ORACLE);
        vm.prank(emergencyGuardian);
        registry.tripMarketBreaker(marketId);
        rm.setLive(marketId, BreakerReasons.ISSUER | BreakerReasons.CONFIG_DRIFT);
        vm.prank(aaveGuardian);
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.ConditionStillHolds.selector, mKey, BreakerReasons.ISSUER)
        );
        registry.resetMarketBreaker(marketId);
        // CONFIG_DRIFT holds but was never latched: it does not block the reset of the latched reasons.
        rm.setLive(marketId, BreakerReasons.CONFIG_DRIFT);
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.BreakerReset(BreakerScope.Market, mKey, aaveGuardian);
        vm.prank(aaveGuardian);
        registry.resetMarketBreaker(marketId);
        (uint32 latched, uint64 last) = registry.marketBreaker(marketId);
        assertEq(latched, 0);
        assertEq(last, 5000, "a reset leaves the temporary-gate breach time");
    }

    // TEST-228 verifies: REQ-MREG-025, REQ-MREG-026, Q-399, REQ-ACCESS-158, REQ-ACCESS-170
    function test_TEST_228_debtResetAfterDeficitCovered() public {
        // Nothing latched yet: a reset has nothing to clear.
        vm.prank(aaveGuardian);
        vm.expectRevert(IMarketRegistryErrors.NothingToReset.selector);
        registry.resetDebtBreaker(address(spoke), GHO_RESERVE);
        vm.prank(address(rm));
        registry.recordBreach(dKey, BreakerReasons.DEFICIT);
        rm.setLiveDebt(address(spoke), GHO_RESERVE, BreakerReasons.DEFICIT);
        vm.prank(emergencyGuardian);
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.ConditionStillHolds.selector, dKey, BreakerReasons.DEFICIT)
        );
        registry.resetDebtBreaker(address(spoke), GHO_RESERVE);
        rm.setLiveDebt(address(spoke), GHO_RESERVE, 0);
        vm.prank(address(timelock));
        registry.resetDebtBreaker(address(spoke), GHO_RESERVE);
        (uint32 latched,) = registry.debtBreaker(address(spoke), GHO_RESERVE);
        assertEq(latched, 0);
    }

    // TEST-228 verifies: REQ-MREG-026
    function testFuzz_TEST_228_latchIsMonotoneUntilReset(
        uint32[6] calldata reasons
    ) public {
        uint32 expected = 0;
        for (uint256 i = 0; i < reasons.length; ++i) {
            vm.prank(address(rm));
            registry.recordBreach(mKey, reasons[i]);
            expected |= reasons[i] & BreakerReasons.SECURITY;
            (uint32 latched,) = registry.marketBreaker(marketId);
            assertEq(latched, expected);
        }
    }
}
