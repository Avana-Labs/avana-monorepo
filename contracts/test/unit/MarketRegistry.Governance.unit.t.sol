// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {MarketRegistryImmutables} from "../../src/policy/market-registry/types/MarketRegistryImmutables.sol";
import {MarketRegistryLogics} from "../../src/policy/market-registry/types/MarketRegistryLogics.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryTokenMock} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice The MarketRegistry driven through the real AvanaTimelock: admin writes run as timelock operations at the
/// normal delay and never earlier, a guardian can cancel them, an upgrade keeps every record, and a move to a new
/// timelock is an upgrade whose implementation names it.
contract MarketRegistryGovernanceUnitTest is MarketRegistryFixture {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal marketId;
    address internal vt;

    function setUp() public {
        _setUpWorld();
        (marketId, vt,) = _activeMarket();
    }

    // TEST-063 verifies: REQ-MREG-004, REQ-CONFIG-002, REQ-CONFIG-017, INV-065
    // Sources: 5.1 TEST-063
    // A registry write scheduled by the governance multisig needs the normal delay: it cannot run a second early, runs
    // from the ready time through the public executor, and takes effect only then.
    function test_TEST_063_adminWriteRunsAtTheNormalDelay() public {
        RegistryTokenMock dai = new RegistryTokenMock(18);
        (address[] memory p, address[] memory a, address[] memory s) = _routes("dai");
        ps.setTolerance(address(dai), 100, 50);
        Call[] memory calls =
            _one(address(registry), abi.encodeCall(registry.listToken, (address(dai), _tokenDef(p, a, s))));
        assertEq(_required(calls), NORMAL_DELAY, "listToken is a normal-delay write");
        bytes32 salt = keccak256("listDai");
        _schedule(governanceMultisig, calls, NORMAL_DELAY, salt);
        vm.warp(block.timestamp + NORMAL_DELAY - 1);
        (address[] memory t, uint256[] memory v, bytes[] memory d) = _arrays(calls);
        vm.prank(attacker);
        vm.expectRevert();
        timelock.executeBatch(t, v, d, bytes32(0), salt);
        assertFalse(registry.getToken(address(dai)).listed);
        vm.warp(block.timestamp + 1);
        _execute(attacker, calls, salt);
        assertTrue(registry.getToken(address(dai)).listed);
    }

    // TEST-063 verifies: REQ-MREG-004, REQ-CONFIG-002
    // A scheduled registry write that a guardian cancels never runs.
    function test_TEST_063_guardianCancelsAScheduledWrite() public {
        Call[] memory calls = _one(address(registry), abi.encodeCall(registry.setCrossHubLinesEnabled, (true)));
        bytes32 salt = keccak256("crossHub");
        bytes32 id = _schedule(governanceMultisig, calls, NORMAL_DELAY, salt);
        vm.prank(emergencyGuardian);
        timelock.cancel(id);
        vm.warp(block.timestamp + NORMAL_DELAY);
        (address[] memory t, uint256[] memory v, bytes[] memory d) = _arrays(calls);
        vm.prank(attacker);
        vm.expectRevert();
        timelock.executeBatch(t, v, d, bytes32(0), salt);
        assertFalse(registry.crossHubLinesEnabled());
    }

    // TEST-063 verifies: REQ-MREG-004, REQ-MREG-022, Q-263
    // The timelock's own stops and lifts run through the same path: a freeze, an unfreeze of an address and an unpause
    // as one batch.
    function test_TEST_063_stopsAndLiftsAsOneBatch() public {
        vm.prank(emergencyGuardian);
        registry.pause(address(hub), PauseReason.General);
        vm.prank(emergencyGuardian);
        registry.freezeAddress(bob);
        Call[] memory calls = _two(
            Call(address(registry), abi.encodeCall(registry.unpause, (address(hub)))),
            Call(address(registry), abi.encodeCall(registry.unfreezeAddress, (bob)))
        );
        _run(calls, keccak256("lift"));
        assertEq(uint8(registry.pauseState(address(hub))), 0);
        assertFalse(registry.isFrozenAddress(bob));
    }

    /// @dev A digest of the registry's records across every family of views.
    function _digest() internal view returns (bytes32) {
        return keccak256(abi.encode(_recordsDigest(), _slotsDigest(), _stopsDigest(), _windDownDigest()));
    }

    function _recordsDigest() internal view returns (bytes32) {
        bytes memory a =
            abi.encode(registry.getMarket(marketId), registry.getToken(address(usdc)), registry.getToken(address(gho)));
        bytes memory b = abi.encode(registry.getSpoke(address(spoke)), registry.getSpokes(), registry.getHubs());
        bytes memory c = abi.encode(
            registry.getDebtReserve(address(spoke), GHO_RESERVE),
            registry.getDebtReserveIds(address(spoke)),
            registry.marketsOfSpoke(address(spoke))
        );
        return keccak256(abi.encode(a, b, c));
    }

    function _slotsDigest() internal view returns (bytes32) {
        (address r0, bool u0) = registry.getRoute(marketId, address(usdc), address(gho), 0);
        (address r1, bool u1) = registry.getRoute(marketId, address(usdt), address(gho), 1);
        (uint256 line, uint256 sum) = registry.creditLine(address(hub), address(gho));
        return keccak256(abi.encode(r0, u0, r1, u1, line, sum));
    }

    function _stopsDigest() internal view returns (bytes32) {
        (uint32 ml, uint64 mt) = registry.marketBreaker(marketId);
        (uint32 dl, uint64 dt) = registry.debtBreaker(address(spoke), GHO_RESERVE);
        bytes memory a = abi.encode(ml, mt, dl, dt);
        bytes memory b = abi.encode(
            registry.pauseState(address(hub)),
            registry.pauseReason(address(hub)),
            registry.isFrozenAddress(bob),
            registry.freezesInWindow(emergencyGuardian)
        );
        return keccak256(abi.encode(a, b));
    }

    function _windDownDigest() internal view returns (bytes32) {
        bytes memory a = abi.encode(
            registry.priceRouteVersion(address(usdc)),
            registry.standbySwitchLockedUntil(address(usdc)),
            registry.windDownState(marketId),
            registry.settlementReserve(marketId)
        );
        bytes memory b = abi.encode(
            registry.flashSource(),
            registry.crossHubLinesEnabled(),
            registry.coverageSpokeOf(address(hub), address(gho)),
            registry.marketOfVaultToken(vt),
            registry.activeMarketCount(address(spoke))
        );
        return keccak256(abi.encode(a, b));
    }

    /// @dev Fills every family of records: pause and reason, a frozen address, latches and breach times, a disabled
    /// route, a standby switch cancelled by the DAO, cross-Hub lines on, an offboarding market with one ramp step.
    function _fill() internal {
        vm.startPrank(emergencyGuardian);
        registry.pause(address(hub), PauseReason.MintPathSuspect);
        registry.freezeAddress(bob);
        registry.tripDebtBreaker(address(spoke), GHO_RESERVE);
        registry.useStandbyRoute(address(usdc), RouteSlot.Alternate);
        vm.stopPrank();
        vm.prank(aaveGovernanceExecutor);
        registry.cancelStandbySwitch(address(usdc));
        vm.prank(address(rm));
        registry.recordBreach(bytes32(marketId), BreakerReasons.ISSUER | BreakerReasons.ORACLE);
        vm.startPrank(address(timelock));
        registry.disableRoute(marketId, address(usdt), address(gho), 1);
        registry.setCrossHubLinesEnabled(true);
        registry.setMarketOffboarding(marketId);
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
    }

    // TEST-168 verifies: REQ-CONFIG-001, REQ-CONFIG-002, INV-065, REQ-MREG-003, REQ-ACCESS-015, REQ-ACCESS-031
    // Sources: 5.1 TEST-168, TEST-137
    // An upgrade through the timelock at the normal delay replaces the implementation and keeps every record; the
    // close of the offboarding market runs on the new implementation from the kept offboarding record.
    function test_TEST_168_upgradeThroughTheTimelockKeepsEveryRecord() public {
        _fill();
        bytes32 before = _digest();
        MarketRegistry next = new MarketRegistry(im, logics);
        Call[] memory calls =
            _one(address(registry), abi.encodeCall(registry.upgradeToAndCall, (address(next), bytes(""))));
        assertEq(_required(calls), NORMAL_DELAY);
        _run(calls, keccak256("upgrade"));
        assertEq(address(uint160(uint256(vm.load(address(registry), IMPLEMENTATION_SLOT)))), address(next));
        // The digest reads the clock (freeze window, lock end); compare at the same time as before the upgrade.
        vm.warp(block.timestamp - NORMAL_DELAY);
        assertEq(_digest(), before, "a record changed across the upgrade");
        // Offboarded with a 7,500 bps reserve: the published target 3,750 survives the upgrade and the market closes.
        vm.warp(block.timestamp + NORMAL_DELAY + 1 days);
        assertEq(registry.windDownState(marketId).targetLtBps, 3750);
        registry.closeMarket(marketId);
    }

    // TEST-242 verifies: REQ-MREG-005, REQ-ACCESS-153, INV-084, Q-259
    // Sources: 5.1 TEST-242
    // Moving to a new timelock is an upgrade to an implementation whose TIMELOCK names it: only then can the admin
    // roles be granted to it, and the old timelock then renounces them.
    function test_TEST_242_newTimelockOnlyThroughAnUpgrade() public {
        address newTimelock = makeAddr("newTimelock");
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.AdminRoleOnlyTimelock.selector, APP_ADMIN, newTimelock)
        );
        registry.grantRole(APP_ADMIN, newTimelock);
        MarketRegistryImmutables memory im2 = im;
        im2.timelock = newTimelock;
        MarketRegistryLogics memory l2 = _deployLogics(im2);
        MarketRegistry next = new MarketRegistry(im2, l2);
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(next), "");
        assertEq(registry.TIMELOCK(), newTimelock);
        bytes32 defaultAdmin = registry.DEFAULT_ADMIN_ROLE();
        vm.startPrank(address(timelock));
        // The old timelock still holds the roles stored in the proxy, and may now hand them only to the new one.
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.AdminRoleOnlyTimelock.selector, APP_ADMIN, alice));
        registry.grantRole(APP_ADMIN, alice);
        registry.grantRole(APP_ADMIN, newTimelock);
        registry.grantRole(defaultAdmin, newTimelock);
        registry.renounceRole(APP_ADMIN, address(timelock));
        registry.renounceRole(defaultAdmin, address(timelock));
        vm.stopPrank();
        assertTrue(registry.hasRole(APP_ADMIN, newTimelock));
        assertFalse(registry.hasRole(APP_ADMIN, address(timelock)));
        vm.prank(newTimelock);
        registry.setCrossHubLinesEnabled(true);
        assertTrue(registry.crossHubLinesEnabled());
    }

    // TEST-168 verifies: REQ-CONFIG-001, REQ-CONFIG-002
    // An upgrade to an implementation built with other logic contracts swaps the write bodies with it; the records
    // stay.
    function test_TEST_168_newLogicContractsArriveOnlyWithAnUpgrade() public {
        MarketRegistryLogics memory fresh = _deployLogics(im);
        MarketRegistry next = new MarketRegistry(im, fresh);
        bytes32 before = _digest();
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(next), "");
        assertEq(_digest(), before);
        // The registry's writes now run through the new logic contracts.
        vm.prank(emergencyGuardian);
        registry.freeze(address(hub));
        assertEq(uint8(registry.pauseState(address(hub))), 1);
    }
}
