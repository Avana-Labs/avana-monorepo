// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {MarketRegistryGuardianHandler} from "./handlers/MarketRegistryGuardianHandler.sol";

/// @title MarketRegistryPauseStateInvariantTest
/// @notice TEST-101: the pause-state machine of the MarketRegistry under random guardian, admin and stranger calls on
/// three Hubs (Stable, Correlated, Volatile tiers) and time warps. The handler checks each call against the transition
/// model of REQ-MREG-001 and REQ-MREG-024 and the role rules of REQ-MREG-004; the invariants read its ghosts and the
/// registry's state.
contract MarketRegistryPauseStateInvariantTest is MarketRegistryFixture {
    MarketRegistryGuardianHandler internal handler;
    address internal freezeOnly = makeAddr("freezeOnlyGuardian");
    address internal pauseOnly = makeAddr("pauseOnlyGuardian");
    address internal correlatedHub = makeAddr("correlatedLpHub");
    address internal volatileHub = makeAddr("volatileLpHub");
    address internal unrecorded = makeAddr("unrecordedHub");

    function setUp() public {
        _setUpWorld();
        vm.startPrank(address(timelock));
        registry.recordHub(correlatedHub, RiskTier.Correlated);
        registry.recordHub(volatileHub, RiskTier.Volatile);
        registry.grantRole(FREEZE_GUARDIAN, freezeOnly);
        registry.grantRole(PAUSE_GUARDIAN, pauseOnly);
        vm.stopPrank();
        handler = new MarketRegistryGuardianHandler(
            registry,
            [address(hub), correlatedHub, volatileHub],
            [emergencyGuardian, freezeOnly, pauseOnly, address(timelock), attacker],
            unrecorded
        );
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](9);
        actions[0] = MarketRegistryGuardianHandler.freeze.selector;
        actions[1] = MarketRegistryGuardianHandler.pause.selector;
        actions[2] = MarketRegistryGuardianHandler.pause.selector;
        actions[3] = MarketRegistryGuardianHandler.unfreeze.selector;
        actions[4] = MarketRegistryGuardianHandler.unpause.selector;
        actions[5] = MarketRegistryGuardianHandler.freezeAll.selector;
        actions[6] = MarketRegistryGuardianHandler.pauseAll.selector;
        actions[7] = MarketRegistryGuardianHandler.warp.selector;
        actions[8] = MarketRegistryGuardianHandler.freeze.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    // TEST-101 verifies: REQ-MREG-001, REQ-MREG-004, REQ-MREG-024, INV-049, INV-050, Q-227, Q-228, SPEC-GOV-004
    // Sources: 5.1 TEST-101, QNT-32, QNT-33
    function invariant_TEST_101_everyCallFollowsTheModel() public view {
        assertEq(handler.outcomeMismatch(), 0, "a call succeeded or failed against the model");
        assertEq(handler.stateMismatch(), 0, "a state or reason differs from the model");
        assertEq(handler.refusedButChanged(), 0, "a refused call changed the state");
    }

    // TEST-101 verifies: REQ-MREG-004, REQ-MREG-017, INV-049, Q-227
    function invariant_TEST_101_rolesBoundTheTransitions() public view {
        assertEq(handler.strangerSucceeded(), 0, "an unauthorised address changed the pause state");
        assertEq(handler.freezeOnlyLoosened(), 0, "the freeze guardian moved a Hub toward None");
    }

    // TEST-101 verifies: REQ-MREG-001, REQ-MREG-024, INV-049
    function invariant_TEST_101_everyChangeEmitsItsEvent() public view {
        assertEq(handler.eventMismatch(), 0, "a change without its exact event, or an event without a change");
    }

    // TEST-101 verifies: REQ-MREG-003, INV-049, Q-227, REQ-ACCESS-090
    function invariant_TEST_101_noStateExpires() public view {
        assertEq(handler.timeChangedState(), 0, "a warp changed the pause state");
    }

    // TEST-101 verifies: REQ-MREG-024, INV-049
    // The reason is None exactly when the Hub is not Paused, on every Hub after every call.
    function invariant_TEST_101_reasonOnlyWhilePaused() public view {
        for (uint256 i = 0; i < handler.HUBS(); ++i) {
            address h = handler.hubAt(i);
            bool paused = registry.pauseState(h) == PauseState.Paused;
            assertEq(registry.pauseReason(h) != PauseReason.None, paused, "reason set iff Paused");
        }
        assertEq(uint8(registry.pauseState(unrecorded)), uint8(PauseState.None), "unrecorded Hub");
    }
}
