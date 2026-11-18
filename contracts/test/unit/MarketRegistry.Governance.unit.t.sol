// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {
    MarketRegistryImmutables,
    MarketRegistryLogics
} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
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
        (address[] memory p, address[] memory a) = _routes("dai");
        Call[] memory calls =
            _one(address(registry), abi.encodeCall(registry.listToken, (address(dai), _tokenDef(p, a))));
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
        Call[] memory calls =
            _one(address(registry), abi.encodeCall(registry.approveSpokeCodeHash, (keccak256("cancelled"))));
        bytes32 salt = keccak256("codeHash");
        bytes32 id = _schedule(governanceMultisig, calls, NORMAL_DELAY, salt);
        vm.prank(emergencyGuardian);
        timelock.cancel(id);
        vm.warp(block.timestamp + NORMAL_DELAY);
        (address[] memory t, uint256[] memory v, bytes[] memory d) = _arrays(calls);
        vm.prank(attacker);
        vm.expectRevert();
        timelock.executeBatch(t, v, d, bytes32(0), salt);
        assertFalse(registry.isApprovedSpokeCodeHash(keccak256("cancelled")));
    }

    /// @dev A digest of the registry's records across every family of views.
    function _digest() internal view returns (bytes32) {
        return keccak256(abi.encode(_recordsDigest(), _slotsDigest(), _windDownDigest()));
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
        (uint256 sum, uint256 required, uint256 funded) = registry.drawCapCoverage(address(hub), address(gho));
        return keccak256(abi.encode(r0, u0, r1, u1, sum, required, funded));
    }

    function _windDownDigest() internal view returns (bytes32) {
        bytes memory a = abi.encode(
            registry.getToken(address(usdc)).alternateRoute,
            registry.windDownState(marketId),
            registry.settlementReserve(marketId)
        );
        bytes memory b = abi.encode(
            registry.flashSource(),
            registry.isApprovedSpokeCodeHash(keccak256("fill")),
            registry.firstLossReserveOf(address(hub), address(gho)),
            registry.marketOfVaultToken(vt),
            registry.activeMarketCount(address(spoke))
        );
        return keccak256(abi.encode(a, b));
    }

    /// @dev Fills every family of records: a disabled route, an approved Spoke code hash, an offboarding market with
    /// one ramp step.
    function _fill() internal {
        vm.startPrank(address(timelock));
        registry.disableRoute(marketId, address(usdt), address(gho), 1);
        registry.approveSpokeCodeHash(keccak256("fill"));
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
        // The digest reads the clock (lock end); compare at the same time as before the upgrade.
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
            abi.encodeWithSelector(IMarketRegistryBase.AdminRoleOnlyTimelock.selector, APP_ADMIN, newTimelock)
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
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.AdminRoleOnlyTimelock.selector, APP_ADMIN, alice));
        registry.grantRole(APP_ADMIN, alice);
        registry.grantRole(APP_ADMIN, newTimelock);
        registry.grantRole(defaultAdmin, newTimelock);
        registry.renounceRole(APP_ADMIN, address(timelock));
        registry.renounceRole(defaultAdmin, address(timelock));
        vm.stopPrank();
        assertTrue(registry.hasRole(APP_ADMIN, newTimelock));
        assertFalse(registry.hasRole(APP_ADMIN, address(timelock)));
        vm.prank(newTimelock);
        registry.approveSpokeCodeHash(keccak256("new timelock"));
        assertTrue(registry.isApprovedSpokeCodeHash(keccak256("new timelock")));
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
        vm.prank(address(timelock));
        registry.approveSpokeCodeHash(keccak256("fresh"));
        assertTrue(registry.isApprovedSpokeCodeHash(keccak256("fresh")));
    }
}
