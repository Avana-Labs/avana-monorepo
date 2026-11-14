// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaTimelock} from "../../src/governance/timelock/AvanaTimelock.sol";
import {IAvanaTimelockErrors} from "../../src/governance/timelock/IAvanaTimelockErrors.sol";
import {IAvanaTimelockEvents} from "../../src/governance/timelock/IAvanaTimelockEvents.sol";
import {IAvanaTimelockGovernance} from "../../src/governance/timelock/IAvanaTimelockGovernance.sol";
import {GovernedTargets} from "../../src/governance/timelock/types/GovernedTargets.sol";
import {SelectorPair} from "../../src/governance/timelock/types/SelectorPair.sol";
import {ILPVaultSwapAdmin} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapAdmin.sol";
import {IMarketRegistryFreeze} from "../../src/policy/market-registry/IMarketRegistryFreeze.sol";
import {IMarketRegistryRoutes} from "../../src/policy/market-registry/IMarketRegistryRoutes.sol";
import {IMarketRegistryStandby} from "../../src/policy/market-registry/IMarketRegistryStandby.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {TimelockFixture} from "../utils/fixtures/TimelockFixture.sol";
import {TimelockLaunchLists} from "../utils/fixtures/TimelockLaunchLists.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice A target that calls back into the timelock while its operation executes.
contract ReentrantTarget {
    AvanaTimelock public timelock;
    bytes public callback;

    function arm(
        AvanaTimelock timelock_,
        bytes calldata callback_
    ) external {
        timelock = timelock_;
        callback = callback_;
    }

    fallback() external {
        (bool ok, bytes memory ret) = address(timelock).call(callback);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @title AvanaTimelockEdgesUnitTest
/// @notice Edge cases of the AvanaTimelock found in review: public execution only through its toggle, the timelock's
/// own admin role kept for life, constructor role and selector checks, overflow-free expiry, single-call scheduling and
/// execution, reentrancy through an executed call, lifecycle orderings, payload edges and events.
contract AvanaTimelockEdgesUnitTest is TimelockFixture {
    bytes32 internal constant SALT = keccak256("edge");
    bytes32 internal EXECUTOR;

    function setUp() public {
        vm.warp(1_780_000_000);
        _deployTimelock();
        EXECUTOR = timelock.EXECUTOR_ROLE();
    }

    function _execRevert(
        TimelockFixture.Call[] memory calls,
        bytes memory reason
    ) internal {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.expectRevert(reason);
        timelock.executeBatch(t, v, p, bytes32(0), SALT);
    }

    function _scheduleAndWait(
        TimelockFixture.Call[] memory calls
    ) internal returns (bytes32 id) {
        id = _schedule(governanceMultisig, calls, NORMAL_DELAY, SALT);
        vm.warp(block.timestamp + NORMAL_DELAY);
    }

    // ─── Public execution only through togglePublicExecution (REQ-ACCESS-144, review finding 1) ───

    // TEST-194 verifies: REQ-ACCESS-144, REQ-ACCESS-029, REQ-ACCESS-020
    function test_TEST_194_openExecutorRoleOnlyThroughToggle() public {
        TimelockFixture.Call[] memory revoke = _self(abi.encodeCall(IAccessControl.revokeRole, (EXECUTOR, address(0))));
        bytes32 id = _scheduleAndWait(revoke);
        assertTrue(timelock.isRoleChangeOperation(id), "would be DAO-only to cancel");
        _execRevert(revoke, abi.encodeWithSelector(IAvanaTimelockErrors.PublicExecutionOnlyByToggle.selector));
        assertTrue(timelock.publicExecution(), "still public");
        // The toggle itself is an ordinary operation: every canceller may stop it.
        bytes32 off = _schedule(
            governanceMultisig,
            _self(abi.encodeCall(IAvanaTimelockGovernance.togglePublicExecution, (false))),
            NORMAL_DELAY,
            SALT
        );
        assertFalse(timelock.isRoleChangeOperation(off));
        vm.prank(emergencyGuardian);
        timelock.cancel(off);
    }

    // TEST-194 verifies: REQ-ACCESS-144, REQ-ACCESS-183
    function test_TEST_194_grantOfOpenExecutorRefused() public {
        _run(_self(abi.encodeCall(IAvanaTimelockGovernance.togglePublicExecution, (false))), SALT);
        TimelockFixture.Call[] memory grant = _self(abi.encodeCall(IAccessControl.grantRole, (EXECUTOR, address(0))));
        _schedule(governanceMultisig, grant, NORMAL_DELAY, SALT);
        vm.warp(block.timestamp + NORMAL_DELAY);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(grant);
        vm.prank(governanceMultisig);
        vm.expectRevert(IAvanaTimelockErrors.PublicExecutionOnlyByToggle.selector);
        timelock.executeBatch(t, v, p, bytes32(0), SALT);
        assertFalse(timelock.publicExecution());
    }

    // TEST-194 verifies: REQ-ACCESS-144
    function test_TEST_194_toggleToSameValueEmitsNothing() public {
        TimelockFixture.Call[] memory on = _self(abi.encodeCall(IAvanaTimelockGovernance.togglePublicExecution, (true)));
        _schedule(governanceMultisig, on, NORMAL_DELAY, SALT);
        vm.warp(block.timestamp + NORMAL_DELAY);
        vm.recordLogs();
        _execute(attacker, on, SALT);
        assertEq(vm.getRecordedLogs().length, 1, "only CallExecuted");
        assertTrue(timelock.publicExecution());
    }

    // ─── The timelock keeps its own admin role (REQ-ACCESS-182, review finding 2) ───

    // TEST-242 verifies: REQ-ACCESS-182, REQ-ACCESS-001, REQ-ACCESS-013, INV-084, REQ-ACCESS-026, REQ-ACCESS-114
    function test_TEST_242_selfAdminCannotBeRevokedOrRenounced() public {
        bytes32 admin = timelock.DEFAULT_ADMIN_ROLE();
        TimelockFixture.Call[] memory revoke =
            _self(abi.encodeCall(IAccessControl.revokeRole, (admin, address(timelock))));
        _scheduleAndWait(revoke);
        _execRevert(revoke, abi.encodeWithSelector(IAvanaTimelockErrors.TimelockAdminRequired.selector));
        TimelockFixture.Call[] memory renounce =
            _self(abi.encodeCall(IAccessControl.renounceRole, (admin, address(timelock))));
        _schedule(governanceMultisig, renounce, NORMAL_DELAY, SALT);
        vm.warp(block.timestamp + NORMAL_DELAY);
        _execRevert(renounce, abi.encodeWithSelector(IAvanaTimelockErrors.TimelockAdminRequired.selector));
        assertTrue(timelock.hasRole(admin, address(timelock)));
    }

    // ─── Constructor checks (REQ-ACCESS-142, REQ-ACCESS-181, REQ-ACCESS-183) ───

    function _deployWith(
        address[] memory proposers,
        address[] memory executors,
        address[] memory cancellers,
        address[] memory dao
    ) internal returns (AvanaTimelock) {
        SelectorPair[] memory none = new SelectorPair[](0);
        return new AvanaTimelock(proposers, executors, cancellers, dao, NORMAL_DELAY, true, none, none, _targets());
    }

    function _list(
        address a
    ) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _list(
        address a,
        address b
    ) internal pure returns (address[] memory l) {
        l = new address[](2);
        (l[0], l[1]) = (a, b);
    }

    // TEST-224 verifies: REQ-ACCESS-183, REQ-ACCESS-160, REQ-ACCESS-027
    function test_TEST_224_constructorRefusesBrokenRoleTables() public {
        address[] memory two = _list(governanceMultisig, aaveGovernanceExecutor);
        address[] memory exec = _list(governanceMultisig);
        address[] memory canc = _list(emergencyGuardian, aaveGuardian);
        address[] memory dao = _list(aaveGovernanceExecutor);
        bytes4 err = IAvanaTimelockErrors.InvalidRoleHolders.selector;
        vm.expectRevert(err);
        _deployWith(_list(governanceMultisig), exec, canc, dao); // one proposer
        vm.expectRevert(err);
        _deployWith(two, exec, canc, new address[](0)); // no DAO canceller
        vm.expectRevert(err);
        _deployWith(two, _list(address(0)), canc, dao); // zero executor (would open execution)
        vm.expectRevert(err);
        _deployWith(_list(governanceMultisig, address(0)), exec, canc, dao);
        vm.expectRevert(err);
        _deployWith(two, exec, _list(emergencyGuardian, address(0)), dao);
        vm.expectRevert(err);
        _deployWith(two, exec, canc, _list(bob)); // DAO canceller without CANCELLER_ROLE
        _deployWith(two, exec, canc, dao);
    }

    function _expectShort(
        address target,
        bytes4 selector
    ) internal {
        SelectorPair[] memory one = new SelectorPair[](1);
        one[0] = SelectorPair(target, selector);
        vm.expectRevert(
            abi.encodeWithSelector(IAvanaTimelockErrors.InvalidShortDelaySelector.selector, target, selector)
        );
        _newTimelockWith(NORMAL_DELAY, true, one, new SelectorPair[](0), _targets());
    }

    function _expectDao(
        address target,
        bytes4 selector
    ) internal {
        SelectorPair[] memory one = new SelectorPair[](1);
        one[0] = SelectorPair(target, selector);
        vm.expectRevert(
            abi.encodeWithSelector(IAvanaTimelockErrors.InvalidDaoCancelSelector.selector, target, selector)
        );
        _newTimelockWith(NORMAL_DELAY, true, new SelectorPair[](0), one, _targets());
    }

    // TEST-244 verifies: REQ-ACCESS-155, REQ-ACCESS-156, REQ-ACCESS-181
    /// @notice Every pair must name the deployed contract its selector belongs to: a `tighten*` selector only the
    /// ParameterStore, a MarketRegistry stop or repair only the MarketRegistry, `removeKeeper` and `addKeeper` only
    /// LPVaultSwap; a pair naming another target, or a contract outside the three, reverts.
    function test_TEST_244_constructorRefusesPairsOnTheWrongTarget() public {
        address ps = address(parameterStore);
        address mr = address(marketRegistry);
        address lvs = address(lpVaultSwap);
        bytes4 cap = IParameterStoreTighten.tightenMarketUsdCap.selector;
        bytes4 disable = IMarketRegistryRoutes.disableRoute.selector;
        bytes4 remove = ILPVaultSwapAdmin.removeKeeper.selector;
        _expectShort(mr, cap);
        _expectShort(lvs, cap);
        _expectShort(address(other), cap);
        _expectShort(ps, disable);
        _expectShort(lvs, disable);
        _expectShort(ps, remove);
        _expectShort(mr, remove);
        bytes4 restore = IMarketRegistryRoutes.restoreRoute.selector;
        bytes4 unfreeze = IMarketRegistryFreeze.unfreezeAddress.selector;
        bytes4 add = ILPVaultSwapAdmin.addKeeper.selector;
        _expectDao(lvs, restore);
        _expectDao(ps, restore);
        _expectDao(lvs, unfreeze);
        _expectDao(mr, add);
        _expectDao(address(other), add);
        // The right targets pass: every launch pair, each with its own contract.
        AvanaTimelock t = _newTimelock(
            NORMAL_DELAY,
            true,
            TimelockLaunchLists.shortEligible(ps, mr, lvs),
            TimelockLaunchLists.daoOnlyCancel(mr, lvs)
        );
        assertTrue(t.isShortEligible(ps, cap));
        assertFalse(t.isShortEligible(mr, cap));
    }

    // TEST-244 verifies: REQ-ACCESS-155, REQ-ACCESS-156
    /// @notice The three governed targets must be non-zero, distinct and not the timelock.
    function test_TEST_244_constructorRefusesBrokenTargets() public {
        address[] memory proposers = _list(governanceMultisig, aaveGovernanceExecutor);
        address[] memory executors = _list(governanceMultisig);
        address[] memory cancellers = _list(emergencyGuardian, aaveGuardian);
        address[] memory dao = _list(aaveGovernanceExecutor);
        SelectorPair[] memory none = new SelectorPair[](0);
        address a = address(parameterStore);
        address b = address(marketRegistry);
        address c = address(lpVaultSwap);
        GovernedTargets[6] memory bad = [
            GovernedTargets(address(0), b, c),
            GovernedTargets(a, address(0), c),
            GovernedTargets(a, b, address(0)),
            GovernedTargets(a, a, c),
            GovernedTargets(a, b, b),
            GovernedTargets(c, b, c)
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.expectRevert(IAvanaTimelockErrors.InvalidGovernedTargets.selector);
            new AvanaTimelock(proposers, executors, cancellers, dao, NORMAL_DELAY, true, none, none, bad[i]);
        }
        // The timelock's own (predicted) address as a target.
        address self = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(IAvanaTimelockErrors.InvalidGovernedTargets.selector);
        new AvanaTimelock(
            proposers, executors, cancellers, dao, NORMAL_DELAY, true, none, none, GovernedTargets(a, self, c)
        );
    }

    // TEST-244 verifies: REQ-ACCESS-142, REQ-ACCESS-155, REQ-ACCESS-181, INV-090
    function test_TEST_244_constructorRefusesNonLaunchSelectors() public {
        SelectorPair[] memory launch =
            TimelockLaunchLists.shortEligible(address(parameterStore), address(marketRegistry), address(lpVaultSwap));
        SelectorPair[] memory dao = TimelockLaunchLists.daoOnlyCancel(address(marketRegistry), address(lpVaultSwap));
        bytes4 loosen = bytes4(keccak256("loosenMarketUsdCap(uint256,uint256)"));
        bytes4 setPriceSource = bytes4(keccak256("setPriceSource(address,uint8,address)"));
        // A loosening selector at the last index of the short list.
        launch[launch.length - 1] = SelectorPair(address(parameterStore), loosen);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAvanaTimelockErrors.InvalidShortDelaySelector.selector, address(parameterStore), loosen
            )
        );
        _newTimelock(NORMAL_DELAY, true, launch, dao);
        // A short-list selector that is not one of the four DAO-only selectors, at index 2.
        launch =
            TimelockLaunchLists.shortEligible(address(parameterStore), address(marketRegistry), address(lpVaultSwap));
        dao[2] = SelectorPair(address(marketRegistry), IMarketRegistryRoutes.disableRoute.selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAvanaTimelockErrors.InvalidDaoCancelSelector.selector,
                address(marketRegistry),
                IMarketRegistryRoutes.disableRoute.selector
            )
        );
        _newTimelock(NORMAL_DELAY, true, launch, dao);
        dao[2] = SelectorPair(address(marketRegistry), setPriceSource);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAvanaTimelockErrors.InvalidDaoCancelSelector.selector, address(marketRegistry), setPriceSource
            )
        );
        _newTimelock(NORMAL_DELAY, true, launch, dao);
    }

    // TEST-244 verifies: REQ-ACCESS-156
    function test_TEST_244_useStandbyRouteIsDaoOnly() public view {
        assertTrue(
            timelock.isDaoOnlyCancelSelector(address(marketRegistry), IMarketRegistryStandby.useStandbyRoute.selector)
        );
    }

    // TEST-194 verifies: REQ-ACCESS-144, REQ-ACCESS-027
    function test_TEST_194_constructionEvents() public {
        SelectorPair[] memory launch =
            TimelockLaunchLists.shortEligible(address(parameterStore), address(marketRegistry), address(lpVaultSwap));
        SelectorPair[] memory dao = TimelockLaunchLists.daoOnlyCancel(address(marketRegistry), address(lpVaultSwap));
        vm.recordLogs();
        AvanaTimelock off = _newTimelock(NORMAL_DELAY, false, launch, dao);
        assertFalse(off.publicExecution());
        (uint256 normal, uint256 shortSet, uint256 toggled) = _countEvents(address(off));
        assertEq(normal, 1, "NormalDelayChanged(0, d)");
        assertEq(shortSet, 34, "ShortDelaySelectorSet per launch entry");
        assertEq(toggled, 1, "PublicExecutionToggled(false)");
    }

    function _countEvents(
        address emitter
    ) internal view returns (uint256 normal, uint256 shortSet, uint256 toggled) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != emitter || logs[i].topics.length == 0) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == IAvanaTimelockEvents.NormalDelayChanged.selector) ++normal;
            if (topic == IAvanaTimelockEvents.ShortDelaySelectorSet.selector) ++shortSet;
            if (topic == IAvanaTimelockEvents.PublicExecutionToggled.selector) {
                ++toggled;
                assertFalse(abi.decode(logs[i].data, (bool)));
            }
        }
    }

    // TEST-244 verifies: REQ-ACCESS-141, REQ-ACCESS-029
    function test_TEST_244_setShortDelaySelectorEmits() public {
        bytes4 cap = IParameterStoreTighten.tightenMarketUsdCap.selector;
        TimelockFixture.Call[] memory off = _self(
            abi.encodeCall(IAvanaTimelockGovernance.setShortDelaySelector, (address(parameterStore), cap, false))
        );
        _schedule(governanceMultisig, off, NORMAL_DELAY, SALT);
        vm.warp(block.timestamp + NORMAL_DELAY);
        vm.expectEmit(true, true, false, true, address(timelock));
        emit IAvanaTimelockEvents.ShortDelaySelectorSet(address(parameterStore), cap, false);
        _execute(attacker, off, SALT);
    }

    // ─── Overflow-free expiry (SPEC-GOV-013, review finding 3) ───

    // TEST-194 verifies: SPEC-GOV-013, REQ-ACCESS-126, REQ-ACCESS-110
    function test_TEST_194_hugeDelayNeverOverflowsExpiry() public {
        uint256 delay = type(uint256).max - block.timestamp;
        TimelockFixture.Call[] memory calls = _one(address(other), hex"deadbeef");
        bytes32 id = _schedule(governanceMultisig, calls, delay, SALT);
        assertEq(timelock.getTimestamp(id), type(uint256).max);
        assertFalse(timelock.isOperationExpired(id), "view never reverts");
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.OperationNotExpired.selector, id));
        timelock.cleanupExpiredOperation(id);
        vm.prank(emergencyGuardian);
        timelock.cancel(id);
    }

    // ─── Single-call schedule and execute ───

    // TEST-244 verifies: REQ-ACCESS-143, REQ-ACCESS-156, SPEC-GOV-005
    function test_TEST_244_singleScheduleSetsMarks() public {
        bytes memory role = abi.encodeCall(IAccessControl.grantRole, (keccak256("R"), bob));
        vm.prank(governanceMultisig);
        timelock.schedule(address(other), 0, role, bytes32(0), SALT, NORMAL_DELAY);
        bytes32 roleId = timelock.hashOperation(address(other), 0, role, bytes32(0), SALT);
        assertTrue(timelock.isRoleChangeOperation(roleId));
        bytes memory restore = abi.encodeWithSelector(IMarketRegistryRoutes.restoreRoute.selector, 7);
        vm.prank(governanceMultisig);
        timelock.schedule(address(marketRegistry), 0, restore, bytes32(0), SALT, SHORT_DELAY);
        bytes32 restoreId = timelock.hashOperation(address(marketRegistry), 0, restore, bytes32(0), SALT);
        assertTrue(timelock.isRestoringOperation(restoreId));
        vm.prank(aaveGuardian);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.RestoringCancelRestricted.selector, restoreId));
        timelock.cancel(restoreId);
        vm.prank(aaveGovernanceExecutor);
        timelock.cancel(restoreId);
        assertFalse(timelock.isRestoringOperation(restoreId), "mark cleared after DAO cancel");
    }

    // TEST-194 verifies: SPEC-GOV-002, SPEC-GOV-013, REQ-ACCESS-144
    function test_TEST_194_singleExecuteWindowAndPublicPath() public {
        bytes memory data = hex"0a0b0c0d";
        vm.prank(governanceMultisig);
        timelock.schedule(address(other), 0, data, bytes32(0), SALT, NORMAL_DELAY);
        bytes32 id = timelock.hashOperation(address(other), 0, data, bytes32(0), SALT);
        vm.warp(block.timestamp + NORMAL_DELAY + GRACE_PERIOD);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.OperationExpired.selector, id));
        timelock.execute(address(other), 0, data, bytes32(0), SALT);
        timelock.cleanupExpiredOperation(id);
        _run(_self(abi.encodeCall(IAvanaTimelockGovernance.togglePublicExecution, (false))), SALT);
        vm.prank(governanceMultisig);
        timelock.schedule(address(other), 0, data, bytes32(0), SALT, NORMAL_DELAY);
        vm.warp(block.timestamp + NORMAL_DELAY);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.ExecutionNotPublic.selector, attacker));
        timelock.execute(address(other), 0, data, bytes32(0), SALT);
        vm.prank(governanceMultisig);
        timelock.execute(address(other), 0, data, bytes32(0), SALT);
        assertTrue(timelock.isOperationDone(id));
    }

    // ─── Payload edges (SPEC-GOV-001) ───

    // TEST-063 verifies: SPEC-GOV-001, REQ-ACCESS-141
    function test_TEST_063_exactlyFourBytePayloadUsesItsSelector() public view {
        bytes memory four = abi.encodePacked(IParameterStoreTighten.tightenMarketUsdCap.selector);
        assertEq(four.length, 4);
        assertEq(_required(_one(address(parameterStore), four)), SHORT_DELAY);
        assertEq(_required(_one(address(parameterStore), hex"")), NORMAL_DELAY, "empty payload");
    }

    // ─── Reentrancy through an executed call ───

    // TEST-194 verifies: SPEC-GOV-002, REQ-ACCESS-118
    function test_TEST_194_reentrantExecuteOfSameOperationReverts() public {
        ReentrantTarget target = new ReentrantTarget();
        TimelockFixture.Call[] memory calls = _one(address(target), hex"01");
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        target.arm(timelock, abi.encodeCall(TimelockController.executeBatch, (t, v, p, bytes32(0), SALT)));
        bytes32 id = _schedule(governanceMultisig, calls, NORMAL_DELAY, SALT);
        vm.warp(block.timestamp + NORMAL_DELAY);
        vm.expectRevert(); // the inner execute marks it done, so the outer _afterCall finds it not ready
        timelock.executeBatch(t, v, p, bytes32(0), SALT);
        assertFalse(timelock.isOperationDone(id), "nothing executed");
        assertTrue(timelock.isOperationPending(id));
    }

    // TEST-194 verifies: SPEC-GOV-013, REQ-ACCESS-126
    function test_TEST_194_executedCallMayCleanUpAnotherExpiredOperation() public {
        TimelockFixture.Call[] memory stale = _one(address(other), hex"0e0e0e0e");
        bytes32 staleId = _schedule(governanceMultisig, stale, NORMAL_DELAY, SALT);
        ReentrantTarget target = new ReentrantTarget();
        target.arm(timelock, abi.encodeCall(IAvanaTimelockGovernance.cleanupExpiredOperation, (staleId)));
        TimelockFixture.Call[] memory calls = _one(address(target), hex"02");
        vm.warp(block.timestamp + NORMAL_DELAY + GRACE_PERIOD - NORMAL_DELAY);
        _schedule(governanceMultisig, calls, NORMAL_DELAY, SALT);
        vm.warp(block.timestamp + NORMAL_DELAY);
        assertTrue(timelock.isOperationExpired(staleId));
        _execute(attacker, calls, SALT);
        assertEq(timelock.getTimestamp(staleId), 0, "cleaned by the executed call");
    }

    // ─── Lifecycle orderings (SPEC-GOV-013) ───

    // TEST-194 verifies: SPEC-GOV-013, REQ-ACCESS-126, SPEC-GOV-007
    function test_TEST_194_lifecycleOrderings() public {
        TimelockFixture.Call[] memory role =
            _one(address(other), abi.encodeCall(IAccessControl.grantRole, (keccak256("R"), bob)));
        bytes32 id = _schedule(governanceMultisig, role, NORMAL_DELAY, SALT);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(role);
        vm.warp(block.timestamp + NORMAL_DELAY + GRACE_PERIOD);
        // Rescheduling before clean-up: still an operation.
        vm.prank(governanceMultisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(uint256(1))
            )
        );
        timelock.scheduleBatch(t, v, p, bytes32(0), SALT, NORMAL_DELAY);
        timelock.cleanupExpiredOperation(id);
        // Double clean-up and cancel after clean-up both fail.
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.OperationNotExpired.selector, id));
        timelock.cleanupExpiredOperation(id);
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert();
        timelock.cancel(id);
        // A cleaned id as predecessor blocks a dependent operation.
        vm.prank(governanceMultisig);
        timelock.schedule(address(other), 0, hex"0f0f0f0f", id, SALT, NORMAL_DELAY);
        vm.warp(block.timestamp + NORMAL_DELAY);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, id));
        timelock.execute(address(other), 0, hex"0f0f0f0f", id, SALT);
        // Rescheduled, the role-change mark is set again.
        _schedule(governanceMultisig, role, NORMAL_DELAY, SALT);
        assertTrue(timelock.isRoleChangeOperation(id));
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.RoleChangeCancelRestricted.selector, id));
        timelock.cancel(id);
    }

    // TEST-244 verifies: REQ-ACCESS-156
    function test_TEST_244_addKeeperAloneIsRestoringAtNormalDelay() public {
        TimelockFixture.Call[] memory add =
            _one(address(lpVaultSwap), abi.encodeWithSelector(ILPVaultSwapAdmin.addKeeper.selector, keeper));
        assertEq(_required(add), NORMAL_DELAY);
        bytes32 id = _schedule(aaveGovernanceExecutor, add, NORMAL_DELAY, SALT);
        assertTrue(timelock.isRestoringOperation(id));
    }

    // TEST-194 verifies: REQ-ACCESS-144, REQ-ACCESS-029
    function test_TEST_194_emptyBatchIsOrdinaryOperation() public {
        // An empty batch changes no role and restores nothing: neither mark is set, and every canceller may stop it.
        TimelockFixture.Call[] memory none = new TimelockFixture.Call[](0);
        bytes32 id = _schedule(governanceMultisig, none, NORMAL_DELAY, SALT);
        assertFalse(timelock.isRoleChangeOperation(id));
        assertFalse(timelock.isRestoringOperation(id));
        vm.prank(emergencyGuardian);
        timelock.cancel(id);
        assertFalse(timelock.isOperation(id));
    }
}
