// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice A compromised guardian against the MarketRegistry: what it can do is bounded to stops (pause, freeze,
/// at most 20 address freezes per caller per 24 hour buckets, breaker trips, a standby switch), it cannot loosen
/// anything governance tightened, and the timelock can always undo its stops and remove it.
contract MarketRegistryGuardianAbuseUnitTest is MarketRegistryFixture {
    uint256 internal marketId;
    address internal vt;

    function setUp() public {
        _setUpWorld();
        (marketId, vt,) = _activeMarket();
    }

    function _wallet(
        uint256 i
    ) internal pure returns (address) {
        return address(uint160(0xBEEF0000 + i));
    }

    // TEST-229 verifies: REQ-MREG-019, REQ-MREG-020, INV-085, ATTACK-139, Q-242
    // Sources: 5.1 TEST-229, ATTACK-139
    // Refused attempts (a protected address, an address already frozen) use none of the caller's 20 freezes.
    function test_TEST_229_refusedFreezesUseNoAllowance() public {
        vm.warp(500 * 3600);
        address g = emergencyGuardian;
        for (uint256 i = 0; i < 19; ++i) {
            vm.prank(g);
            registry.freezeAddress(_wallet(i));
        }
        address[5] memory protectedSet = [address(registry), address(hub), address(spoke), vt, address(gho)];
        for (uint256 i = 0; i < protectedSet.length; ++i) {
            vm.prank(g);
            vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ProtectedAddress.selector, protectedSet[i]));
            registry.freezeAddress(protectedSet[i]);
        }
        vm.prank(g);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.AddressAlreadyFrozen.selector, _wallet(0)));
        registry.freezeAddress(_wallet(0));
        assertEq(registry.freezesInWindow(g), 19);
        vm.prank(g);
        registry.freezeAddress(_wallet(19));
        assertEq(registry.freezesInWindow(g), 20);
        vm.prank(g);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.FreezeLimitReached.selector, g));
        registry.freezeAddress(_wallet(20));
        assertFalse(registry.isFrozenAddress(_wallet(20)));
    }

    // TEST-229 verifies: REQ-MREG-019, INV-085
    // The order of the freeze checks: AddressAlreadyFrozen, then ProtectedAddress, then the limit. A caller at its
    // limit still learns that an address is already frozen or protected.
    function test_TEST_229_checkOrderAtTheLimit() public {
        vm.warp(600 * 3600);
        for (uint256 i = 0; i < 20; ++i) {
            vm.prank(aaveGuardian);
            registry.freezeAddress(_wallet(i));
        }
        vm.startPrank(aaveGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.AddressAlreadyFrozen.selector, _wallet(3)));
        registry.freezeAddress(_wallet(3));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ProtectedAddress.selector, address(timelock)));
        registry.freezeAddress(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.FreezeLimitReached.selector, aaveGuardian));
        registry.freezeAddress(_wallet(99));
        vm.stopPrank();
    }

    // TEST-229 verifies: REQ-MREG-019, REQ-MREG-004, ATTACK-139
    // Each caller has its own allowance: both guardians together freeze at most 40 wallets in a window, the timelock's
    // own freezes count against the timelock only, and a fresh guardian starts at 0.
    function test_TEST_229_allowancePerCaller() public {
        vm.warp(700 * 3600);
        address[3] memory callers = [emergencyGuardian, aaveGuardian, address(timelock)];
        for (uint256 c = 0; c < 3; ++c) {
            for (uint256 i = 0; i < 20; ++i) {
                vm.prank(callers[c]);
                registry.freezeAddress(_wallet(c * 100 + i));
            }
            vm.prank(callers[c]);
            vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.FreezeLimitReached.selector, callers[c]));
            registry.freezeAddress(_wallet(c * 100 + 50));
            assertEq(registry.freezesInWindow(callers[c]), 20);
        }
        address fresh = makeAddr("freshGuardian");
        vm.prank(address(timelock));
        registry.grantRole(FREEZE_GUARDIAN, fresh);
        assertEq(registry.freezesInWindow(fresh), 0);
        vm.prank(fresh);
        registry.freezeAddress(_wallet(999));
    }

    // TEST-229 verifies: REQ-MREG-019
    // In the first 23 hours of the chain's clock the window starts at hour 0: every freeze since then counts.
    function test_TEST_229_windowNearTheStartOfTime() public {
        vm.warp(0);
        vm.prank(emergencyGuardian);
        registry.freezeAddress(_wallet(0));
        vm.warp(22 * 3600 + 3599);
        vm.prank(emergencyGuardian);
        registry.freezeAddress(_wallet(1));
        assertEq(registry.freezesInWindow(emergencyGuardian), 2);
        vm.warp(23 * 3600);
        assertEq(registry.freezesInWindow(emergencyGuardian), 2, "hour 0 is still inside [0, 23]");
        vm.warp(24 * 3600);
        assertEq(registry.freezesInWindow(emergencyGuardian), 1, "hour 0 has left the window");
    }

    // TEST-229 verifies: REQ-MREG-022, REQ-MREG-019, ATTACK-132
    // An unfreeze returns the address to the pool but not the allowance: re-freezing it counts again.
    function test_TEST_229_refreezeAfterUnfreezeCountsAgain() public {
        vm.warp(800 * 3600);
        vm.prank(emergencyGuardian);
        registry.freezeAddress(bob);
        vm.prank(address(timelock));
        registry.unfreezeAddress(bob);
        vm.prank(emergencyGuardian);
        registry.freezeAddress(bob);
        assertTrue(registry.isFrozenAddress(bob));
        assertEq(registry.freezesInWindow(emergencyGuardian), 2);
    }

    // TEST-065 verifies: REQ-MREG-004, REQ-MREG-005, ATTACK-132, INV-049, Q-227
    // A guardian that re-pauses after every unpause holds the Hub only until the timelock revokes its roles; after
    // that its calls are refused and the timelock lifts the pause.
    function test_TEST_065_repausingGuardianIsRemovedByTheTimelock() public {
        address h = address(hub);
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(aaveGuardian);
            registry.pause(h, PauseReason.MintPathSuspect);
            vm.prank(address(timelock));
            registry.unpause(h);
        }
        vm.prank(aaveGuardian);
        registry.pause(h, PauseReason.MintPathSuspect);
        vm.startPrank(address(timelock));
        registry.revokeRole(PAUSE_GUARDIAN, aaveGuardian);
        registry.revokeRole(FREEZE_GUARDIAN, aaveGuardian);
        registry.unpause(h);
        vm.stopPrank();
        bytes memory unauthorized = abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, aaveGuardian);
        vm.startPrank(aaveGuardian);
        vm.expectRevert(unauthorized);
        registry.pause(h, PauseReason.General);
        vm.expectRevert(unauthorized);
        registry.freeze(h);
        vm.expectRevert(unauthorized);
        registry.freezeAddress(bob);
        vm.expectRevert(unauthorized);
        registry.tripMarketBreaker(marketId);
        vm.expectRevert(unauthorized);
        registry.useStandbyRoute(address(usdc), RouteSlot.Primary);
        vm.stopPrank();
        assertEq(uint8(registry.pauseState(h)), uint8(PauseState.None));
        // The other guardian keeps its powers.
        vm.prank(emergencyGuardian);
        registry.freeze(h);
    }

    // TEST-066 verifies: REQ-MREG-004, REQ-MREG-022, REQ-MREG-025, REQ-CONFIG-062, ATTACK-098, ATTACK-139
    // Sources: 5.1 TEST-066
    // An unpause restores only the pause state: a route governance disabled, an address frozen and a breaker whose
    // condition still holds stay as they were, and the guardian has no call that loosens any of them.
    function test_TEST_066_unpauseLoosensNothingElse() public {
        address h = address(hub);
        vm.prank(emergencyGuardian);
        registry.pause(h, PauseReason.General);
        vm.startPrank(address(timelock));
        registry.disableRoute(marketId, address(usdc), address(gho), 0);
        vm.stopPrank();
        vm.prank(emergencyGuardian);
        registry.freezeAddress(bob);
        vm.prank(address(rm));
        registry.recordBreach(bytes32(marketId), BreakerReasons.ISSUER);
        rm.setLive(marketId, BreakerReasons.ISSUER);

        vm.prank(aaveGuardian);
        registry.unpause(h);
        assertEq(uint8(registry.pauseState(h)), uint8(PauseState.None));
        (address route, bool usable) = registry.getRoute(marketId, address(usdc), address(gho), 0);
        assertFalse(usable, "the disabled route stays disabled");
        assertTrue(registry.isFrozenAddress(bob), "the frozen address stays frozen");
        (uint32 latched,) = registry.marketBreaker(marketId);
        assertEq(latched, BreakerReasons.ISSUER, "the latch stays");

        bytes memory notAdmin =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, aaveGuardian, APP_ADMIN);
        vm.startPrank(aaveGuardian);
        vm.expectRevert(notAdmin);
        registry.restoreRoute(marketId, address(usdc), address(gho), 0, route);
        vm.expectRevert(notAdmin);
        registry.unfreezeAddress(bob);
        vm.expectRevert(notAdmin);
        registry.setRoute(marketId, address(usdc), address(gho), 0, route);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryErrors.ConditionStillHolds.selector, bytes32(marketId), BreakerReasons.ISSUER
            )
        );
        registry.resetMarketBreaker(marketId);
        vm.stopPrank();
    }

    // TEST-228 verifies: REQ-MREG-025, ATTACK-139, Q-241
    // A guardian may trip every market and debt breaker at once; with no live condition the other guardian (or the
    // timelock) resets each, and the trip leaves no breach time behind.
    function test_TEST_228_tripEverythingThenResetEverything() public {
        vm.startPrank(emergencyGuardian);
        registry.tripMarketBreaker(marketId);
        registry.tripDebtBreaker(address(spoke), GHO_RESERVE);
        vm.stopPrank();
        (uint32 m, uint64 mt) = registry.marketBreaker(marketId);
        (uint32 d, uint64 dt) = registry.debtBreaker(address(spoke), GHO_RESERVE);
        assertEq(m, BreakerReasons.MANUAL);
        assertEq(d, BreakerReasons.MANUAL);
        assertEq(mt, 0, "a manual trip is no temporary breach");
        assertEq(dt, 0);
        vm.prank(aaveGuardian);
        registry.resetMarketBreaker(marketId);
        vm.prank(address(timelock));
        registry.resetDebtBreaker(address(spoke), GHO_RESERVE);
        (m,) = registry.marketBreaker(marketId);
        (d,) = registry.debtBreaker(address(spoke), GHO_RESERVE);
        assertEq(m, 0);
        assertEq(d, 0);
    }

    // TEST-231 verifies: REQ-MREG-028, REQ-CONFIG-009, ATTACK-139, ATTACK-140
    // A guardian's standby switch can only pick the token's pre-approved standby route, never a new feed, and the
    // Aave executor's cancel returns the recorded routes at once.
    function test_TEST_231_switchPicksOnlyThePreApprovedStandby() public {
        address t = address(usdc);
        address[] memory standby = registry.getToken(t).standbyRoute;
        address[] memory alternate = registry.getToken(t).alternateRoute;
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(t, RouteSlot.Alternate);
        (address[] memory p, address[] memory a,) = registry.activePriceRoutes(t);
        assertEq(a.length, standby.length);
        assertEq(a[0], standby[0]);
        assertEq(p[0], registry.getToken(t).primaryRoute[0]);
        vm.prank(aaveGovernanceExecutor);
        registry.cancelStandbySwitch(t);
        (, a,) = registry.activePriceRoutes(t);
        assertEq(a.length, alternate.length);
        assertEq(a[0], alternate[0]);
        assertEq(a[1], alternate[1]);
    }
}
