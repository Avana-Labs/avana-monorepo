// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "../../src/policy/market-registry/IMarketRegistryEvents.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {IMarketRegistrySafetyEvents} from "../../src/policy/market-registry/IMarketRegistrySafetyEvents.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";

/// @notice Per-Hub pause state and reason of the MarketRegistry.
contract MarketRegistryPauseUnitTest is MarketRegistryFixture {
    address internal correlatedHub = makeAddr("correlatedLpHub");

    function setUp() public {
        _setUpWorld();
        vm.prank(address(timelock));
        registry.recordHub(correlatedHub, RiskTier.Correlated);
    }

    function _state(
        address h
    ) internal view returns (PauseState) {
        return registry.pauseState(h);
    }

    // TEST-065 verifies: REQ-MREG-001, REQ-MREG-004, REQ-MREG-017, REQ-MREG-024, INV-049, Q-227, Q-252, REQ-ACCESS-062, REQ-ACCESS-063, REQ-ACCESS-085, REQ-ACCESS-086, REQ-ACCESS-123, REQ-ACCESS-162, SPEC-GOV-004, REQ-ACCESS-064, REQ-ACCESS-088, REQ-RISK-037
    // Sources: 5.1 TEST-065, QNT-T13
    function test_TEST_065_transitionsAndEvents() public {
        address h = address(hub);
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.PauseStateChanged(h, PauseState.None, PauseState.Frozen, emergencyGuardian);
        vm.prank(emergencyGuardian);
        registry.freeze(h);
        vm.prank(emergencyGuardian);
        vm.expectRevert(IMarketRegistryErrors.AlreadyFrozen.selector);
        registry.freeze(h);
        assertEq(uint8(registry.pauseReason(h)), uint8(PauseReason.None));

        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.PauseStateChanged(h, PauseState.Frozen, PauseState.Paused, aaveGuardian);
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.PauseReasonChanged(h, PauseReason.None, PauseReason.General, aaveGuardian);
        vm.prank(aaveGuardian);
        registry.pause(h, PauseReason.General);

        vm.startPrank(emergencyGuardian);
        vm.expectRevert(IMarketRegistryErrors.AlreadyPaused.selector);
        registry.freeze(h);
        vm.expectRevert(IMarketRegistryErrors.InvalidPauseReason.selector);
        registry.pause(h, PauseReason.General);
        vm.expectRevert(IMarketRegistryErrors.InvalidPauseReason.selector);
        registry.pause(h, PauseReason.None);
        vm.expectRevert(IMarketRegistryErrors.CannotUnfreezeWhilePaused.selector);
        registry.unfreeze(h);
        // Paused(General) -> Paused(MintPathSuspect): reason changes, state does not.
        vm.recordLogs();
        registry.pause(h, PauseReason.MintPathSuspect);
        assertEq(vm.getRecordedLogs().length, 1);
        assertEq(uint8(registry.pauseReason(h)), uint8(PauseReason.MintPathSuspect));
        registry.unpause(h);
        vm.stopPrank();
        assertEq(uint8(_state(h)), uint8(PauseState.None));
        assertEq(uint8(registry.pauseReason(h)), uint8(PauseReason.None));

        vm.startPrank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.NotFrozen.selector);
        registry.unfreeze(h);
        vm.expectRevert(IMarketRegistryErrors.NotPaused.selector);
        registry.unpause(h);
        registry.freeze(h);
        vm.expectRevert(IMarketRegistryErrors.NotPaused.selector);
        registry.unpause(h);
        registry.unfreeze(h);
        vm.stopPrank();
        assertEq(uint8(_state(h)), uint8(PauseState.None));
    }

    // TEST-065 verifies: REQ-MREG-001, REQ-MREG-003, REQ-CONFIG-082, Q-308, REQ-ACCESS-090, REQ-RISK-036
    function test_TEST_065_perHubAndNoExpiry() public {
        vm.prank(emergencyGuardian);
        registry.pause(address(hub), PauseReason.General);
        assertEq(uint8(_state(correlatedHub)), uint8(PauseState.None));
        vm.warp(block.timestamp + 3650 days);
        assertEq(uint8(_state(address(hub))), uint8(PauseState.Paused));
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidHub.selector, alice));
        registry.freeze(alice);
        assertEq(uint8(_state(alice)), uint8(PauseState.None));
    }

    // TEST-065 verifies: REQ-CONFIG-082, REQ-MREG-001, REQ-MREG-024, REQ-ACCESS-172
    function test_TEST_065_freezeAllAndPauseAll() public {
        vm.prank(emergencyGuardian);
        registry.freeze(address(hub));
        vm.prank(emergencyGuardian);
        registry.freezeAll();
        assertEq(uint8(_state(correlatedHub)), uint8(PauseState.Frozen));
        vm.prank(emergencyGuardian);
        vm.expectRevert(IMarketRegistryErrors.AlreadyFrozen.selector);
        registry.freezeAll();

        vm.prank(aaveGuardian);
        registry.pause(address(hub), PauseReason.MintPathSuspect);
        vm.prank(aaveGuardian);
        vm.expectRevert(IMarketRegistryErrors.InvalidPauseReason.selector);
        registry.pauseAll(PauseReason.None);
        vm.prank(aaveGuardian);
        registry.pauseAll(PauseReason.MintPathSuspect);
        assertEq(uint8(_state(correlatedHub)), uint8(PauseState.Paused));
        assertEq(uint8(registry.pauseReason(correlatedHub)), uint8(PauseReason.MintPathSuspect));
        vm.prank(aaveGuardian);
        vm.expectRevert(IMarketRegistryErrors.AlreadyPaused.selector);
        registry.pauseAll(PauseReason.MintPathSuspect);
        vm.prank(aaveGuardian);
        registry.pauseAll(PauseReason.General);
        assertEq(uint8(registry.pauseReason(address(hub))), uint8(PauseReason.General));
    }

    // TEST-065 verifies: REQ-MREG-001, REQ-MREG-024, INV-049
    function testFuzz_TEST_065_reasonNoneExactlyWhenNotPaused(
        uint8[12] calldata ops
    ) public {
        address h = address(hub);
        for (uint256 i = 0; i < ops.length; ++i) {
            uint8 op = ops[i] % 6;
            vm.prank(i % 2 == 0 ? emergencyGuardian : address(timelock));
            if (op == 0) {
                try registry.freeze(h) {} catch {}
            } else if (op == 1) {
                try registry.pause(h, PauseReason.General) {} catch {}
            } else if (op == 2) {
                try registry.pause(h, PauseReason.MintPathSuspect) {} catch {}
            } else if (op == 3) {
                try registry.unfreeze(h) {} catch {}
            } else if (op == 4) {
                try registry.unpause(h) {} catch {}
            } else {
                try registry.pauseAll(PauseReason.General) {} catch {}
            }
            bool paused = _state(h) == PauseState.Paused;
            assertEq(paused, registry.pauseReason(h) != PauseReason.None);
        }
    }
}
