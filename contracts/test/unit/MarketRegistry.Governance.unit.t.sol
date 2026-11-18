// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {MarketRegistryLogics} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryTokenMock} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice The MarketRegistry driven through the real AccessManager: admin writes run as scheduled operations at the
/// governance delay and never earlier, the DAO can cancel them, and an upgrade keeps every record.
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
    // A registry write scheduled by the governance multisig needs the governance delay: it cannot run a second early,
    // runs from the ready time, and takes effect only then.
    function test_TEST_063_adminWriteRunsAtTheGovernanceDelay() public {
        RegistryTokenMock dai = new RegistryTokenMock(18);
        (address[] memory p, address[] memory a) = _routes("dai");
        bytes memory data = abi.encodeCall(registry.listToken, (address(dai), _tokenDef(p, a)));
        assertEq(_delayOf(address(registry), data), NORMAL_DELAY, "listToken is a governance-delay write");
        (, uint256 readyAt) = _scheduleOp(governanceMultisig, address(registry), data);
        vm.warp(readyAt - 1);
        vm.prank(governanceMultisig);
        vm.expectRevert();
        accessManager.execute(address(registry), data);
        assertFalse(registry.getToken(address(dai)).listed);
        vm.warp(readyAt);
        vm.prank(governanceMultisig);
        accessManager.execute(address(registry), data);
        assertTrue(registry.getToken(address(dai)).listed);
    }

    // TEST-063 verifies: REQ-MREG-004, REQ-CONFIG-002
    // A scheduled registry write that the DAO cancels never runs.
    function test_TEST_063_daoCancelsAScheduledWrite() public {
        bytes memory data = abi.encodeCall(registry.approveSpokeCodeHash, (keccak256("cancelled")));
        (bytes32 id,) = _scheduleOp(governanceMultisig, address(registry), data);
        vm.prank(aaveGovernanceExecutor);
        accessManager.cancel(governanceMultisig, address(registry), data);
        assertEq(accessManager.getSchedule(id), 0, "cancelled");
        vm.warp(block.timestamp + NORMAL_DELAY);
        vm.prank(governanceMultisig);
        vm.expectRevert();
        accessManager.execute(address(registry), data);
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
        vm.startPrank(governor);
        registry.disableRoute(marketId, address(usdt), address(gho), 1);
        registry.approveSpokeCodeHash(keccak256("fill"));
        registry.setMarketOffboarding(marketId);
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
    }

    // TEST-168 verifies: REQ-CONFIG-001, REQ-CONFIG-002, INV-065, REQ-MREG-003, REQ-ACCESS-015, REQ-ACCESS-031
    // Sources: 5.1 TEST-168, TEST-137
    // An upgrade through the AccessManager at the governance delay replaces the implementation and keeps every record; the
    // close of the offboarding market runs on the new implementation from the kept offboarding record.
    function test_TEST_168_upgradeThroughTheAccessManagerKeepsEveryRecord() public {
        _fill();
        bytes32 before = _digest();
        MarketRegistry next = new MarketRegistry(im, logics);
        bytes memory data = abi.encodeCall(registry.upgradeToAndCall, (address(next), bytes("")));
        assertEq(_delayOf(address(registry), data), NORMAL_DELAY);
        _runScheduled(address(registry), data);
        assertEq(address(uint160(uint256(vm.load(address(registry), IMPLEMENTATION_SLOT)))), address(next));
        // The digest reads the clock (lock end); compare at the same time as before the upgrade.
        vm.warp(block.timestamp - NORMAL_DELAY);
        assertEq(_digest(), before, "a record changed across the upgrade");
        // Offboarded with a 7,500 bps reserve: the published target 3,750 survives the upgrade and the market closes.
        vm.warp(block.timestamp + NORMAL_DELAY + 1 days);
        assertEq(registry.windDownState(marketId).targetLtBps, 3750);
        registry.closeMarket(marketId);
    }

    // TEST-168 verifies: REQ-CONFIG-001, REQ-CONFIG-002
    // An upgrade to an implementation built with other logic contracts swaps the write bodies with it; the records
    // stay.
    function test_TEST_168_newLogicContractsArriveOnlyWithAnUpgrade() public {
        MarketRegistryLogics memory fresh = _deployLogics(im);
        MarketRegistry next = new MarketRegistry(im, fresh);
        bytes32 before = _digest();
        vm.prank(governor);
        registry.upgradeToAndCall(address(next), "");
        assertEq(_digest(), before);
        // The registry's writes now run through the new logic contracts.
        vm.prank(governor);
        registry.approveSpokeCodeHash(keccak256("fresh"));
        assertTrue(registry.isApprovedSpokeCodeHash(keccak256("fresh")));
    }
}
