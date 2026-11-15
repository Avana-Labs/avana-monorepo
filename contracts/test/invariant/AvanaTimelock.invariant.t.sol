// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {TimelockFixture} from "../utils/fixtures/TimelockFixture.sol";
import {TimelockHandler} from "./handlers/TimelockHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";

/// @title AvanaTimelockInvariantTest
/// @notice TEST-212: random sequences of scheduling (short, normal, mixed, role-change, restoring and
/// `setNormalDelay` operations), cancels by every canceller and by strangers, public execution, clean-up and time
/// steps of 1 hour to 20 days. After every call: nothing executed before its ready time or from ready + 14 days on,
/// nothing scheduled below its required delay, no role-change or restoring operation cancelled without the DAO
/// canceller, the normal delay inside its bounds, the minimum delay and the admin role unchanged.
contract AvanaTimelockInvariantTest is TimelockFixture, HandlerReach {
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

    // TEST-082 verifies: TEST-007
    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls from set-up, counts per action the calls that
    /// changed the state of a contract other than the handler and this test, the skipped and failed calls and the
    /// calls that returned without changing anything; each action must change the state in at least its floor of
    /// calls (`forge test -vv` prints the table).
    function test_TEST_082_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r = _replayLanded(address(handler), actions, TimelockHandler.Skipped.selector, 32, 50, 0, own, true);
        _check(r, names, new string[](0), _floors(5, 0), new uint256[](0));
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions() internal pure returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds) {
        (actions, names, kinds) = (new bytes4[](5), new string[](5), new int16[][](5));
        (actions[0], names[0]) = (TimelockHandler.schedule.selector, "schedule");
        kinds[0] = new int16[](4);
        kinds[0][0] = 8;
        kinds[0][1] = 8;
        kinds[0][2] = 256;
        kinds[0][3] = 256;
        (actions[1], names[1]) = (TimelockHandler.execute.selector, "execute");
        kinds[1] = new int16[](3);
        kinds[1][0] = 256;
        kinds[1][1] = 160;
        kinds[1][2] = 1;
        (actions[2], names[2]) = (TimelockHandler.cancel.selector, "cancel");
        kinds[2] = new int16[](3);
        kinds[2][0] = 256;
        kinds[2][1] = 8;
        kinds[2][2] = 160;
        (actions[3], names[3]) = (TimelockHandler.cleanup.selector, "cleanup");
        kinds[3] = new int16[](1);
        kinds[3][0] = 256;
        (actions[4], names[4]) = (TimelockHandler.warp.selector, "warp");
        kinds[4] = new int16[](1);
        kinds[4][0] = 256;
    }

    function _calldata(bytes4 selector, uint256 seed) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
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

