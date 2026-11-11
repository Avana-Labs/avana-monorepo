// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {TimelockFixture} from "../utils/fixtures/TimelockFixture.sol";
import {TimelockHandler} from "./handlers/TimelockHandler.sol";

/// @title AvanaTimelockInvariantTest
/// @notice TEST-212: random sequences of scheduling (short, normal, mixed, role-change, restoring and
/// `setNormalDelay` operations), cancels by every canceller and by strangers, public execution, clean-up and time
/// steps of 1 hour to 20 days. After every call: nothing executed before its ready time or from ready + 14 days on,
/// nothing scheduled below its required delay, no role-change or restoring operation cancelled without the DAO
/// canceller, the normal delay inside its bounds, the minimum delay and the admin role unchanged.
contract AvanaTimelockInvariantTest is TimelockFixture {
    TimelockHandler internal handler;

    function setUp() public {
        vm.warp(1_780_000_000);
        _deployTimelock();
        handler = new TimelockHandler(
            timelock,
            address(parameterStore),
            address(marketRegistry),
            address(lpVaultSwap),
            address(other),
            [governanceMultisig, aaveGovernanceExecutor],
            [governanceMultisig, emergencyGuardian, aaveGuardian, aaveGovernanceExecutor],
            aaveGovernanceExecutor
        );
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](6);
        actions[0] = TimelockHandler.schedule.selector;
        actions[1] = TimelockHandler.execute.selector;
        actions[2] = TimelockHandler.cancel.selector;
        actions[3] = TimelockHandler.cleanup.selector;
        actions[4] = TimelockHandler.warp.selector;
        actions[5] = TimelockHandler.updateDelay.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    // TEST-212 verifies: SPEC-GOV-001, SPEC-GOV-002, SPEC-GOV-013, REQ-ACCESS-141, REQ-ACCESS-144, INV-051, INV-068, Q-228
    // Sources: 5.1 TEST-212
    function invariant_TEST_212_executionOnlyInsideWindow() public view {
        assertEq(handler.executedEarly(), 0, "executed before readyAt");
        assertEq(handler.executedExpired(), 0, "executed at or after readyAt + GRACE_PERIOD");
    }

    // TEST-212 verifies: SPEC-GOV-001, REQ-ACCESS-117, INV-068
    function invariant_TEST_212_neverScheduledBelowRequired() public view {
        assertEq(handler.scheduledBelowRequired(), 0);
    }

    // TEST-212 verifies: SPEC-GOV-005, REQ-ACCESS-019, REQ-ACCESS-156, INV-068
    function invariant_TEST_212_cancelRights() public view {
        assertEq(handler.roleChangeCancelledByNonDao(), 0, "role change cancelled without DAO canceller");
        assertEq(handler.restoringCancelledByNonDao(), 0, "restoring cancelled without DAO canceller");
        assertEq(handler.cancelledByNonCanceller(), 0, "cancelled without CANCELLER_ROLE");
    }

    // TEST-212 verifies: SPEC-GOV-003, REQ-ACCESS-154, REQ-ACCESS-017, INV-090, INV-084
    function invariant_TEST_212_delaysAndAdminFixed() public view {
        uint256 d = timelock.normalDelay();
        assertGe(d, MIN_NORMAL_DELAY);
        assertLe(d, NORMAL_DELAY);
        assertEq(timelock.getMinDelay(), SHORT_DELAY);
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(handler)));
    }

    // TEST-212 verifies: REQ-ACCESS-144, REQ-ACCESS-182, REQ-ACCESS-141, INV-090
    function invariant_TEST_212_shortListAndRolesStayConsistent() public view {
        bytes4 s = IParameterStoreTighten.tightenMinPledgeUsd.selector;
        assertTrue(
            !timelock.isShortDelaySelector(address(parameterStore), s)
                || timelock.isShortEligible(address(parameterStore), s)
        );
        assertEq(timelock.publicExecution(), timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)), "admin kept for life");
    }
}

