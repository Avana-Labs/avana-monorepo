// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";

/// @title MarketRegistryGuardianRehearsalUnitTest
/// @notice The guardian rehearsal's calls on the real MarketRegistry and the real AvanaTimelock, in the order the
/// runbook runs them: the Emergency Guardian freezes and the Aave Protocol Guardian pauses the Hub, the pause is
/// lifted, the Hub is frozen again and a signer set holding only the freeze role cannot unfreeze while a pause guardian
/// can, and a canceller cancels a queued timelock operation. Normal operation is restored at the end.
/// @dev The guardians are the fixture's addresses standing in for their Safes; the fork run of the deployed Safes'
/// payloads, and the Aave Spoke configurator's `freezeReserve` and `pauseReserve`, are the launch rehearsal itself.
contract MarketRegistryGuardianRehearsalUnitTest is MarketRegistryFixture {
    address internal freezeOnly = makeAddr("freezeOnlySignerSet");

    function setUp() public {
        _setUpWorld();
        bytes32 freezeRole = FREEZE_GUARDIAN;
        vm.prank(address(timelock));
        registry.grantRole(freezeRole, freezeOnly);
    }

    function _state() internal view returns (PauseState) {
        return registry.pauseState(address(hub));
    }

    /// @dev Kills: `unfreeze` open to the freeze role, `freeze` or `pause` closed to either guardian, or a queued
    /// operation a canceller cannot stop.
    // TEST-129 verifies: REQ-ACCESS-062, REQ-ACCESS-063
    function test_TEST_129_guardianRehearsalOnTheRegistryAndTimelock() public {
        address h = address(hub);
        vm.prank(emergencyGuardian);
        registry.freeze(h);
        assertEq(uint8(_state()), uint8(PauseState.Frozen), "Emergency Guardian froze");
        vm.prank(aaveGuardian);
        registry.pause(h, PauseReason.General);
        assertEq(uint8(_state()), uint8(PauseState.Paused), "Aave Protocol Guardian paused");
        vm.prank(aaveGuardian);
        registry.unpause(h);
        assertEq(uint8(_state()), uint8(PauseState.None), "pause lifted");

        vm.prank(freezeOnly);
        registry.freeze(h);
        assertEq(uint8(_state()), uint8(PauseState.Frozen), "freeze-only signer set froze");
        vm.prank(freezeOnly);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, freezeOnly));
        registry.unfreeze(h);
        vm.prank(emergencyGuardian);
        registry.unfreeze(h);
        assertEq(uint8(_state()), uint8(PauseState.None), "normal operation restored");

        Call[] memory op = _one(address(registry), abi.encodeCall(registry.freeze, (h)));
        bytes32 id = _schedule(governanceMultisig, op, _required(op), keccak256("rehearsal"));
        assertTrue(timelock.isOperationPending(id), "queued");
        vm.prank(emergencyGuardian);
        timelock.cancel(id);
        assertFalse(timelock.isOperation(id), "cancelled");
        assertEq(uint8(_state()), uint8(PauseState.None), "cancelled operation changed nothing");
    }
}
