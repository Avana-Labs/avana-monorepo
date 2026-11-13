// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaTimelock} from "../../src/governance/timelock/AvanaTimelock.sol";
import {IAvanaTimelock} from "../../src/governance/timelock/IAvanaTimelock.sol";
import {IAvanaTimelockErrors} from "../../src/governance/timelock/IAvanaTimelockErrors.sol";
import {IAvanaTimelockEvents} from "../../src/governance/timelock/IAvanaTimelockEvents.sol";
import {IAvanaTimelockGovernance} from "../../src/governance/timelock/IAvanaTimelockGovernance.sol";
import {SelectorPair} from "../../src/governance/timelock/types/SelectorPair.sol";
import {ILPVaultSwapAdmin} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapAdmin.sol";
import {IDebtOracle} from "../../src/oracle/debt-oracle/IDebtOracle.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {IAaveAdapterAdmin} from "../../src/policy/aave-adapter/IAaveAdapterAdmin.sol";
import {IMarketRegistryFreeze} from "../../src/policy/market-registry/IMarketRegistryFreeze.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {IMarketRegistryListing} from "../../src/policy/market-registry/IMarketRegistryListing.sol";
import {IMarketRegistryRoutes} from "../../src/policy/market-registry/IMarketRegistryRoutes.sol";
import {IParameterStoreAdmin} from "../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {IRiskModuleAdmin} from "../../src/policy/risk-module/IRiskModuleAdmin.sol";
import {TimelockFixture} from "../utils/fixtures/TimelockFixture.sol";
import {TimelockLaunchLists} from "../utils/fixtures/TimelockLaunchLists.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title AvanaTimelockUnitTest
/// @notice The AvanaTimelock on its own (2.15): delay classes from calldata, the execution window and expiry,
/// clean-up, public execution, cancel rights for role-change and restoring operations, the timelock's own settings
/// as self-calls, and its own admin role.
contract AvanaTimelockUnitTest is TimelockFixture {
    bytes32 internal constant SALT = keccak256("salt");
    bytes32 internal PROPOSER;
    bytes32 internal EXECUTOR;
    bytes32 internal CANCELLER;

    function setUp() public {
        vm.warp(1_780_000_000);
        _deployTimelock();
        PROPOSER = timelock.PROPOSER_ROLE();
        EXECUTOR = timelock.EXECUTOR_ROLE();
        CANCELLER = timelock.CANCELLER_ROLE();
    }

    // ─── Calls used across tests ───

    function _tighten() internal view returns (TimelockFixture.Call memory) {
        return
            Call(address(parameterStore), abi.encodeCall(IParameterStoreTighten.tightenMarketUsdCap, (1, 4_000_000e8)));
    }

    function _disableRoute() internal view returns (TimelockFixture.Call memory) {
        return Call(address(marketRegistry), abi.encodeWithSelector(IMarketRegistryRoutes.disableRoute.selector, 7));
    }

    function _loosen() internal view returns (TimelockFixture.Call memory) {
        return Call(address(parameterStore), abi.encodeWithSignature("loosenTopUpSliceUsd(uint256,uint256)", 1, 2));
    }

    function _addKeeper() internal view returns (TimelockFixture.Call memory) {
        return Call(address(lpVaultSwap), abi.encodeWithSelector(ILPVaultSwapAdmin.addKeeper.selector, keeper));
    }

    function _restoreRoute() internal view returns (TimelockFixture.Call memory) {
        return Call(address(marketRegistry), abi.encodeWithSelector(IMarketRegistryRoutes.restoreRoute.selector, 7));
    }

    function _roleCall(
        address target
    ) internal view returns (TimelockFixture.Call memory) {
        return Call(target, abi.encodeCall(IAccessControl.grantRole, (keccak256("SOME_ROLE"), bob)));
    }

    // ─── Construction (REQ-ACCESS-027, REQ-ACCESS-140, REQ-ACCESS-155, REQ-ACCESS-156) ───

    // TEST-194 verifies: REQ-ACCESS-140, REQ-ACCESS-017, REQ-ACCESS-030, SPEC-GOV-003, Q-228, Q-262, REQ-ACCESS-114, REQ-ACCESS-067
    // Sources: 5.1 TEST-194, 2.15
    function test_TEST_194_constantsAndLaunchValues() public view {
        assertEq(timelock.SHORT_DELAY(), 43_200);
        assertEq(timelock.MIN_NORMAL_DELAY(), 345_600);
        assertEq(timelock.MAX_DELAY(), 432_000);
        assertEq(timelock.GRACE_PERIOD(), 1_209_600);
        assertEq(timelock.getMinDelay(), 43_200, "getMinDelay");
        assertEq(timelock.normalDelay(), 432_000, "normalDelay");
        assertTrue(timelock.publicExecution(), "public execution at launch");
    }

    // TEST-242 verifies: REQ-ACCESS-001, REQ-ACCESS-004, REQ-ACCESS-005, REQ-ACCESS-006, REQ-ACCESS-007, REQ-ACCESS-013, REQ-ACCESS-027, REQ-ACCESS-153, REQ-ACCESS-160, INV-084
    function test_TEST_242_launchRolesAndSelfAdmin() public view {
        bytes32 admin = timelock.DEFAULT_ADMIN_ROLE();
        assertTrue(timelock.hasRole(admin, address(timelock)), "self admin");
        assertFalse(timelock.hasRole(admin, address(this)), "deployer admin");
        assertFalse(timelock.hasRole(admin, address(0)), "zero admin");
        assertTrue(timelock.hasRole(PROPOSER, governanceMultisig) && timelock.hasRole(PROPOSER, aaveGovernanceExecutor));
        assertTrue(timelock.hasRole(EXECUTOR, governanceMultisig), "executor");
        address[4] memory cancellers = [governanceMultisig, emergencyGuardian, aaveGuardian, aaveGovernanceExecutor];
        for (uint256 i; i < 4; ++i) {
            assertTrue(timelock.hasRole(CANCELLER, cancellers[i]), "canceller");
        }
        assertTrue(timelock.hasRole(_daoCanceller(), aaveGovernanceExecutor), "DAO canceller");
        assertFalse(timelock.hasRole(_daoCanceller(), emergencyGuardian));
        assertTrue(timelock.hasRole(EXECUTOR, address(0)), "public execution is the open executor role");
    }

    // TEST-194 verifies: REQ-ACCESS-140, REQ-ACCESS-154, SPEC-GOV-003, SPEC-GOV-015
    function testFuzz_TEST_194_constructorRefusesNormalDelayOutOfBounds(
        uint256 d
    ) public {
        vm.assume(d < MIN_NORMAL_DELAY || d > NORMAL_DELAY);
        SelectorPair[] memory none = new SelectorPair[](0);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.DelayOutOfBounds.selector, d));
        _newTimelock(d, true, none, none);
    }

    // TEST-244 verifies: REQ-ACCESS-141, REQ-ACCESS-142, REQ-ACCESS-155, INV-090, Q-262
    function test_TEST_244_shortEligibleIsTheLaunchList() public view {
        SelectorPair[] memory launch =
            TimelockLaunchLists.shortEligible(address(parameterStore), address(marketRegistry), address(lpVaultSwap));
        assertEq(launch.length, 34);
        for (uint256 i; i < launch.length; ++i) {
            assertTrue(timelock.isShortEligible(launch[i].target, launch[i].selector), "eligible");
            assertTrue(timelock.isShortDelaySelector(launch[i].target, launch[i].selector), "listed at launch");
        }
        assertTrue(
            timelock.isShortEligible(
                address(parameterStore), IParameterStoreTighten.tightenFloorRoundingAllowance.selector
            )
        );
        assertTrue(
            timelock.isShortEligible(address(parameterStore), IParameterStoreAdmin.tightenMaxFlashFeeBps.selector)
        );
        // Same selector on another target is not eligible: pairs are keyed by target.
        assertFalse(timelock.isShortEligible(address(other), IParameterStoreTighten.tightenMarketUsdCap.selector));
        assertFalse(timelock.isShortEligible(address(lpVaultSwap), ILPVaultSwapAdmin.addKeeper.selector));
    }

    // TEST-244 verifies: REQ-ACCESS-156, SPEC-GOV-005, Q-263
    function test_TEST_244_daoOnlyCancelSetIsTheLaunchSet() public view {
        assertTrue(
            timelock.isDaoOnlyCancelSelector(address(marketRegistry), IMarketRegistryRoutes.restoreRoute.selector)
        );
        assertTrue(
            timelock.isDaoOnlyCancelSelector(address(marketRegistry), IMarketRegistryFreeze.unfreezeAddress.selector)
        );
        assertTrue(timelock.isDaoOnlyCancelSelector(address(lpVaultSwap), ILPVaultSwapAdmin.addKeeper.selector));
        assertFalse(
            timelock.isDaoOnlyCancelSelector(address(marketRegistry), IMarketRegistryRoutes.disableRoute.selector)
        );
    }

    /// @notice No pair whose target is the timelock, and no role, upgrade, flash-source, deployment, cross-Hub or
    /// initializer selector, can be made short-eligible or DAO-only at construction.
    // TEST-244 verifies: REQ-ACCESS-142, REQ-ACCESS-152, REQ-ACCESS-181, INV-090
    function test_TEST_244_constructorRefusesForbiddenPairs() public {
        bytes4[17] memory forbidden = [
            IAccessControl.grantRole.selector,
            IAccessControl.revokeRole.selector,
            IAccessControl.renounceRole.selector,
            UUPSUpgradeable.upgradeToAndCall.selector,
            IMarketRegistryHubs.setFlashSource.selector,
            IMarketRegistryListing.deployCdpSpoke.selector,
            IMarketRegistryListing.listCollateralMarket.selector,
            IMarketRegistryListing.enableDebtReserve.selector,
            IMarketRegistryHubs.setCrossHubLinesEnabled.selector,
            IMarketRegistryHubs.setCrossHubLine.selector,
            IMarketRegistryListing.initialize.selector,
            IParameterStoreAdmin.initialize.selector,
            IAaveAdapterAdmin.initialize.selector,
            IRiskModuleAdmin.initialize.selector,
            ILPOracle.initialize.selector,
            IDebtOracle.initialize.selector,
            ILPVaultSwapAdmin.initialize.selector
        ];
        SelectorPair[] memory none = new SelectorPair[](0);
        SelectorPair[] memory one = new SelectorPair[](1);
        for (uint256 i; i < forbidden.length; ++i) {
            one[0] = SelectorPair(address(marketRegistry), forbidden[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAvanaTimelockErrors.InvalidShortDelaySelector.selector, address(marketRegistry), forbidden[i]
                )
            );
            _newTimelock(NORMAL_DELAY, true, one, none);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAvanaTimelockErrors.InvalidDaoCancelSelector.selector, address(marketRegistry), forbidden[i]
                )
            );
            _newTimelock(NORMAL_DELAY, true, none, one);
        }
    }

    // TEST-244 verifies: REQ-ACCESS-018, REQ-ACCESS-142, REQ-ACCESS-181
    function testFuzz_TEST_244_constructorRefusesTimelockTarget(
        bytes4 selector
    ) public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        SelectorPair[] memory none = new SelectorPair[](0);
        SelectorPair[] memory one = new SelectorPair[](1);
        one[0] = SelectorPair(predicted, selector);
        vm.expectRevert(
            abi.encodeWithSelector(IAvanaTimelockErrors.InvalidShortDelaySelector.selector, predicted, selector)
        );
        _newTimelockWith(NORMAL_DELAY, true, one, none, _targets());
        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        one[0] = SelectorPair(predicted, selector);
        vm.expectRevert(
            abi.encodeWithSelector(IAvanaTimelockErrors.InvalidDaoCancelSelector.selector, predicted, selector)
        );
        _newTimelockWith(NORMAL_DELAY, true, none, one, _targets());
    }

    // ─── requiredDelay and scheduling (SPEC-GOV-001) ───

    // TEST-063 verifies: REQ-ACCESS-141, REQ-ACCESS-016, SPEC-GOV-001, INV-068, Q-228
    // Sources: 5.1 TEST-063 (timelock side), SPEC-GOV-001 example
    function test_TEST_063_shortOnlyWhenEveryCallIsListed() public view {
        assertEq(_required(_two(_tighten(), _disableRoute())), SHORT_DELAY, "all short");
        assertEq(_required(_two(_tighten(), _loosen())), NORMAL_DELAY, "one normal call");
        assertEq(_required(_one(_addKeeper().target, _addKeeper().data)), NORMAL_DELAY, "addKeeper is normal");
        assertEq(
            _required(
                _one(address(lpVaultSwap), abi.encodeWithSelector(ILPVaultSwapAdmin.removeKeeper.selector, keeper))
            ),
            SHORT_DELAY,
            "removeKeeper is short"
        );
        assertEq(_required(new TimelockFixture.Call[](0)), NORMAL_DELAY, "empty");
        assertEq(_required(_one(address(parameterStore), hex"5e4c01")), NORMAL_DELAY, "under four bytes");
        assertEq(
            _required(
                _one(address(timelock), abi.encodeCall(IAvanaTimelockGovernance.setNormalDelay, (MIN_NORMAL_DELAY)))
            ),
            NORMAL_DELAY
        );
    }

    // TEST-063 verifies: REQ-ACCESS-141, SPEC-GOV-001
    function testFuzz_TEST_063_requiredDelayIsShortOrNormal(
        uint8 mask,
        uint8 n
    ) public view {
        n = uint8(bound(n, 0, 6));
        TimelockFixture.Call[] memory calls = new TimelockFixture.Call[](n);
        bool allShort = n > 0;
        for (uint256 i; i < n; ++i) {
            bool short = (mask >> i) & 1 == 1;
            calls[i] = short ? _tighten() : _loosen();
            allShort = allShort && short;
        }
        assertEq(_required(calls), allShort ? SHORT_DELAY : NORMAL_DELAY);
    }

    // TEST-194 verifies: REQ-ACCESS-141, REQ-ACCESS-117, SPEC-GOV-001, INV-068, REQ-ACCESS-111, REQ-ACCESS-148
    function test_TEST_194_scheduleBelowRequiredReverts() public {
        TimelockFixture.Call[] memory calls = _two(_tighten(), _loosen());
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.prank(governanceMultisig);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.DelayBelowRequired.selector, 43_200, 432_000));
        timelock.scheduleBatch(t, v, p, bytes32(0), SALT, 43_200);
        // Below the short delay, OpenZeppelin's own floor answers first.
        vm.prank(governanceMultisig);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, 43_199, 43_200));
        timelock.scheduleBatch(t, v, p, bytes32(0), SALT, 43_199);
        // The single-call form.
        vm.prank(governanceMultisig);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.DelayBelowRequired.selector, 43_200, 432_000));
        timelock.schedule(address(parameterStore), 0, _loosen().data, bytes32(0), SALT, 43_200);
        // A short batch at the short delay is accepted.
        _schedule(governanceMultisig, _two(_tighten(), _disableRoute()), SHORT_DELAY, SALT);
    }

    // TEST-194 verifies: REQ-ACCESS-117, REQ-ACCESS-004
    function test_TEST_194_scheduleChecksInOrder() public {
        TimelockFixture.Call[] memory calls = _one(address(other), hex"12345678");
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, PROPOSER)
        );
        timelock.scheduleBatch(t, v, p, bytes32(0), SALT, 0);
        uint256[] memory badValues = new uint256[](2);
        vm.prank(governanceMultisig);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInvalidOperationLength.selector, 1, 1, 2));
        timelock.scheduleBatch(t, badValues, p, bytes32(0), SALT, NORMAL_DELAY);
        bytes32 id = _schedule(governanceMultisig, calls, NORMAL_DELAY, SALT);
        // Already scheduled beats a short delay.
        vm.prank(governanceMultisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(uint256(1))
            )
        );
        timelock.scheduleBatch(t, v, p, bytes32(0), SALT, 0);
    }

    // TEST-194 verifies: REQ-ACCESS-141
    function test_TEST_194_requiredDelayRevertsOnLengthMismatch() public {
        address[] memory t = new address[](2);
        bytes[] memory p = new bytes[](1);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInvalidOperationLength.selector, 2, 1, 0));
        timelock.requiredDelay(t, p);
    }

    // ─── Execution window (SPEC-GOV-002, SPEC-GOV-013) ───

    // TEST-194 verifies: SPEC-GOV-002, REQ-ACCESS-118, REQ-ACCESS-144, INV-051, INV-068, SPEC-GOV-014, REQ-ACCESS-111
    // Sources: TEST-194 example (addKeeper)
    function test_TEST_194_executesOnlyInsideTheWindow() public {
        uint256 t0 = block.timestamp;
        TimelockFixture.Call[] memory calls = _one(_addKeeper().target, _addKeeper().data);
        bytes32 id = _schedule(governanceMultisig, calls, NORMAL_DELAY, SALT);
        assertEq(timelock.getTimestamp(id), t0 + NORMAL_DELAY);
        vm.warp(t0 + NORMAL_DELAY - 1);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(uint256(1 << 2))
            )
        );
        timelock.executeBatch(t, v, p, bytes32(0), SALT);
        vm.warp(t0 + NORMAL_DELAY);
        _execute(attacker, calls, SALT);
        assertTrue(timelock.isOperationDone(id));
        assertEq(lpVaultSwap.callCount(), 1);
        assertEq(lpVaultSwap.callAt(0).caller, address(timelock), "msg.sender at the target");
    }

    // TEST-194 verifies: SPEC-GOV-002, SPEC-GOV-013, REQ-ACCESS-118, INV-068
    function test_TEST_194_expiresAtReadyPlusGrace() public {
        TimelockFixture.Call[] memory calls = _one(address(other), hex"aabbccdd");
        bytes32 id = _schedule(governanceMultisig, calls, NORMAL_DELAY, SALT);
        uint256 readyAt = timelock.getTimestamp(id);
        // A second operation scheduled later, still inside its own window when the first expires.
        vm.warp(readyAt + GRACE_PERIOD - NORMAL_DELAY);
        bytes32 id2 = _schedule(governanceMultisig, calls, NORMAL_DELAY, keccak256("second"));
        vm.warp(readyAt + GRACE_PERIOD - 1);
        assertFalse(timelock.isOperationExpired(id));
        vm.warp(readyAt + GRACE_PERIOD);
        assertTrue(timelock.isOperationExpired(id));
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.OperationExpired.selector, id));
        timelock.executeBatch(t, v, p, bytes32(0), SALT);
        // The second operation is still inside its window.
        _execute(attacker, calls, keccak256("second"));
        assertTrue(timelock.isOperationDone(id2));
    }

    // TEST-194 verifies: SPEC-GOV-013, REQ-ACCESS-126, REQ-ACCESS-108, REQ-ACCESS-012
    function test_TEST_194_cleanupOnlyAfterExpiryAndAllowsReschedule() public {
        TimelockFixture.Call[] memory calls = _one(address(other), hex"aabbccdd");
        bytes32 unscheduled = _id(calls, SALT);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.OperationNotExpired.selector, unscheduled));
        timelock.cleanupExpiredOperation(unscheduled);
        bytes32 id = _schedule(governanceMultisig, calls, NORMAL_DELAY, SALT);
        vm.warp(timelock.getTimestamp(id) + GRACE_PERIOD - 1);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.OperationNotExpired.selector, id));
        timelock.cleanupExpiredOperation(id);
        vm.warp(block.timestamp + 1);
        vm.expectEmit(true, false, false, false, address(timelock));
        emit IAvanaTimelockEvents.ExpiredOperationCleaned(id);
        vm.prank(attacker);
        timelock.cleanupExpiredOperation(id);
        assertEq(timelock.getTimestamp(id), 0, "timestamp");
        assertEq(uint8(timelock.getOperationState(id)), uint8(TimelockController.OperationState.Unset));
        assertFalse(timelock.isOperationExpired(id));
        assertFalse(timelock.isOperationPending(id));
        // The same calls can be scheduled again, with a fresh delay.
        uint256 t1 = block.timestamp;
        _schedule(governanceMultisig, calls, NORMAL_DELAY, SALT);
        assertEq(timelock.getTimestamp(id), t1 + NORMAL_DELAY, "fresh readyAt");
        vm.warp(t1 + NORMAL_DELAY);
        _execute(attacker, calls, SALT);
        assertTrue(timelock.isOperationDone(id));
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.OperationNotExpired.selector, id));
        timelock.cleanupExpiredOperation(id);
    }

    // TEST-194 verifies: REQ-ACCESS-118
    function test_TEST_194_unexecutedPredecessorBlocks() public {
        TimelockFixture.Call[] memory first = _one(address(other), hex"01020304");
        bytes32 firstId = _schedule(governanceMultisig, first, NORMAL_DELAY, SALT);
        vm.prank(governanceMultisig);
        timelock.schedule(address(other), 0, hex"05060708", firstId, SALT, NORMAL_DELAY);
        vm.warp(block.timestamp + NORMAL_DELAY);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, firstId));
        timelock.execute(address(other), 0, hex"05060708", firstId, SALT);
    }

    // ─── Public execution (REQ-ACCESS-144) ───

    // TEST-194 verifies: REQ-ACCESS-144, REQ-ACCESS-021, REQ-ACCESS-029, REQ-ACCESS-012, REQ-ACCESS-129
    function test_TEST_194_publicExecutionToggle() public {
        TimelockFixture.Call[] memory off =
            _self(abi.encodeCall(IAvanaTimelockGovernance.togglePublicExecution, (false)));
        _schedule(governanceMultisig, off, NORMAL_DELAY, SALT);
        vm.warp(block.timestamp + NORMAL_DELAY);
        vm.expectEmit(false, false, false, true, address(timelock));
        emit IAvanaTimelockEvents.PublicExecutionToggled(false);
        _execute(attacker, off, SALT);
        assertFalse(timelock.publicExecution());
        assertFalse(timelock.hasRole(EXECUTOR, address(0)));
        TimelockFixture.Call[] memory calls = _one(address(other), hex"0badf00d");
        _schedule(governanceMultisig, calls, NORMAL_DELAY, SALT);
        vm.warp(block.timestamp + NORMAL_DELAY);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.ExecutionNotPublic.selector, attacker));
        timelock.executeBatch(t, v, p, bytes32(0), SALT);
        _execute(governanceMultisig, calls, SALT);
        // Turning it back on is again a self-call operation, executed by the executor.
        TimelockFixture.Call[] memory on = _self(abi.encodeCall(IAvanaTimelockGovernance.togglePublicExecution, (true)));
        _schedule(governanceMultisig, on, NORMAL_DELAY, SALT);
        vm.warp(block.timestamp + NORMAL_DELAY);
        _execute(governanceMultisig, on, SALT);
        assertTrue(timelock.publicExecution());
    }

    // ─── Cancel rights (SPEC-GOV-005, SPEC-GOV-007) ───

    // TEST-244 verifies: REQ-ACCESS-005, REQ-ACCESS-020, SPEC-GOV-005, SPEC-GOV-007, Q-136
    function testFuzz_TEST_244_ordinaryOperationCancellableByEveryCanceller(
        uint8 who
    ) public {
        address[4] memory cancellers = [governanceMultisig, emergencyGuardian, aaveGuardian, aaveGovernanceExecutor];
        address c = cancellers[who % 4];
        bytes32 id = _schedule(governanceMultisig, _two(_tighten(), _loosen()), NORMAL_DELAY, SALT);
        vm.prank(c);
        timelock.cancel(id);
        assertFalse(timelock.isOperation(id));
    }

    // TEST-244 verifies: REQ-ACCESS-119, SPEC-GOV-005
    function test_TEST_244_nonCancellerCannotCancel() public {
        bytes32 id = _schedule(governanceMultisig, _two(_tighten(), _loosen()), NORMAL_DELAY, SALT);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, CANCELLER)
        );
        timelock.cancel(id);
    }

    // TEST-244 verifies: REQ-ACCESS-019, REQ-ACCESS-024, REQ-ACCESS-143, SPEC-GOV-005, Q-136, REQ-ACCESS-026, REQ-ACCESS-112
    // Sources: SPEC-GOV-005 example
    function test_TEST_244_roleChangeCancelledOnlyByDao() public {
        TimelockFixture.Call[] memory pure_ =
            _one(_roleCall(address(marketRegistry)).target, _roleCall(address(marketRegistry)).data);
        bytes32 id = _schedule(governanceMultisig, pure_, NORMAL_DELAY, SALT);
        assertTrue(timelock.isRoleChangeOperation(id));
        address[3] memory others = [governanceMultisig, emergencyGuardian, aaveGuardian];
        for (uint256 i; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.RoleChangeCancelRestricted.selector, id));
            timelock.cancel(id);
        }
        vm.prank(aaveGovernanceExecutor);
        timelock.cancel(id);
        assertFalse(timelock.isRoleChangeOperation(id), "mark cleared");
        // A role call mixed with an upgrade is cancellable by every canceller.
        TimelockFixture.Call memory upgrade =
            Call(address(other), abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(1), "")));
        bytes32 mixed =
            _schedule(governanceMultisig, _two(upgrade, _roleCall(address(marketRegistry))), NORMAL_DELAY, SALT);
        assertFalse(timelock.isRoleChangeOperation(mixed));
        vm.prank(emergencyGuardian);
        timelock.cancel(mixed);
    }

    // TEST-244 verifies: REQ-ACCESS-156, REQ-ACCESS-119, SPEC-GOV-005, Q-263, REQ-ACCESS-112
    function test_TEST_244_restoringCancelledOnlyByDao() public {
        TimelockFixture.Call[] memory restoring = _two(_restoreRoute(), _addKeeper());
        assertEq(_required(restoring), NORMAL_DELAY, "addKeeper is normal");
        bytes32 id = _schedule(governanceMultisig, restoring, NORMAL_DELAY, SALT);
        assertTrue(timelock.isRestoringOperation(id));
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.RestoringCancelRestricted.selector, id));
        timelock.cancel(id);
        // At the short delay too: restoreRoute alone is short and restoring.
        bytes32 shortRestore =
            _schedule(governanceMultisig, _one(_restoreRoute().target, _restoreRoute().data), SHORT_DELAY, SALT);
        assertTrue(timelock.isRestoringOperation(shortRestore));
        vm.prank(governanceMultisig);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.RestoringCancelRestricted.selector, shortRestore));
        timelock.cancel(shortRestore);
        vm.prank(aaveGovernanceExecutor);
        timelock.cancel(id);
        // Mixed with any other call: ordinary rule.
        bytes32 mixed = _schedule(governanceMultisig, _two(_restoreRoute(), _loosen()), NORMAL_DELAY, SALT);
        assertFalse(timelock.isRestoringOperation(mixed));
        vm.prank(aaveGuardian);
        timelock.cancel(mixed);
    }

    // TEST-244 verifies: SPEC-GOV-007, REQ-ACCESS-020
    function test_TEST_244_cancelledNeverExecutesAndExpiredCanBeCancelled() public {
        TimelockFixture.Call[] memory calls = _one(address(other), hex"cafebabe");
        bytes32 id = _schedule(governanceMultisig, calls, NORMAL_DELAY, SALT);
        vm.prank(emergencyGuardian);
        timelock.cancel(id);
        vm.warp(block.timestamp + NORMAL_DELAY);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(uint256(1 << 2))
            )
        );
        timelock.executeBatch(t, v, p, bytes32(0), SALT);
        bytes32 id2 = _schedule(governanceMultisig, calls, NORMAL_DELAY, keccak256("x"));
        vm.warp(block.timestamp + NORMAL_DELAY + GRACE_PERIOD);
        assertTrue(timelock.isOperationExpired(id2));
        vm.prank(aaveGuardian);
        timelock.cancel(id2);
        assertFalse(timelock.isOperation(id2));
    }

    // TEST-244 verifies: REQ-ACCESS-143, REQ-ACCESS-156
    function test_TEST_244_marksClearedOnExecuteAndCleanup() public {
        bytes32 id = _run(_one(_roleCall(address(other)).target, _roleCall(address(other)).data), SALT);
        assertFalse(timelock.isRoleChangeOperation(id), "after execute");
        bytes32 r = _schedule(governanceMultisig, _one(_restoreRoute().target, _restoreRoute().data), SHORT_DELAY, SALT);
        vm.warp(block.timestamp + SHORT_DELAY + GRACE_PERIOD);
        timelock.cleanupExpiredOperation(r);
        assertFalse(timelock.isRestoringOperation(r), "after clean-up");
    }

    // ─── The timelock's own settings (SPEC-GOV-003, REQ-ACCESS-018, REQ-ACCESS-029) ───

    // TEST-194 verifies: REQ-ACCESS-018, REQ-ACCESS-029, REQ-ACCESS-116
    function test_TEST_194_settersAreSelfCallsOnly() public {
        vm.startPrank(governanceMultisig);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, governanceMultisig)
        );
        timelock.setNormalDelay(MIN_NORMAL_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, governanceMultisig)
        );
        timelock.setShortDelaySelector(
            address(parameterStore), IParameterStoreTighten.tightenMarketUsdCap.selector, false
        );
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, governanceMultisig)
        );
        timelock.togglePublicExecution(false);
        vm.stopPrank();
    }

    // TEST-194 verifies: SPEC-GOV-003, REQ-ACCESS-154, REQ-ACCESS-125, INV-090
    // Sources: SPEC-GOV-003 example
    function test_TEST_194_setNormalDelayAppliesToLaterOperations() public {
        uint256 t0 = block.timestamp;
        TimelockFixture.Call[] memory cut =
            _self(abi.encodeCall(IAvanaTimelockGovernance.setNormalDelay, (MIN_NORMAL_DELAY)));
        assertEq(_required(cut), NORMAL_DELAY, "setNormalDelay is normal");
        _schedule(governanceMultisig, cut, NORMAL_DELAY, SALT);
        bytes32 before = _schedule(governanceMultisig, _one(address(other), hex"11111111"), NORMAL_DELAY, SALT);
        vm.warp(t0 + NORMAL_DELAY);
        vm.expectEmit(false, false, false, true, address(timelock));
        emit IAvanaTimelockEvents.NormalDelayChanged(NORMAL_DELAY, MIN_NORMAL_DELAY);
        _execute(attacker, cut, SALT);
        assertEq(timelock.normalDelay(), MIN_NORMAL_DELAY);
        assertEq(timelock.getTimestamp(before), t0 + NORMAL_DELAY, "already scheduled keeps its readyAt");
        assertEq(_required(_two(_tighten(), _loosen())), MIN_NORMAL_DELAY);
        _schedule(governanceMultisig, _one(address(other), hex"22222222"), MIN_NORMAL_DELAY, SALT);
    }

    // TEST-194 verifies: SPEC-GOV-003, REQ-ACCESS-154, REQ-ACCESS-125, SPEC-GOV-015
    function testFuzz_TEST_194_setNormalDelayBounds(
        uint256 d
    ) public {
        TimelockFixture.Call[] memory calls = _self(abi.encodeCall(IAvanaTimelockGovernance.setNormalDelay, (d)));
        _schedule(governanceMultisig, calls, NORMAL_DELAY, SALT);
        vm.warp(block.timestamp + NORMAL_DELAY);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        if (d < MIN_NORMAL_DELAY || d > NORMAL_DELAY) {
            vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.DelayOutOfBounds.selector, d));
            timelock.executeBatch(t, v, p, bytes32(0), SALT);
            assertEq(timelock.normalDelay(), NORMAL_DELAY);
        } else {
            timelock.executeBatch(t, v, p, bytes32(0), SALT);
            assertEq(timelock.normalDelay(), d);
        }
    }

    // TEST-244 verifies: REQ-ACCESS-141, REQ-ACCESS-142, REQ-ACCESS-152, INV-090, REQ-ACCESS-114, REQ-ACCESS-067
    function test_TEST_244_shortListOnlyWithinEligible() public {
        bytes4 loosen = bytes4(keccak256("loosenTopUpSliceUsd(uint256,uint256)"));
        TimelockFixture.Call[] memory add = _self(
            abi.encodeCall(IAvanaTimelockGovernance.setShortDelaySelector, (address(parameterStore), loosen, true))
        );
        _schedule(governanceMultisig, add, NORMAL_DELAY, SALT);
        vm.warp(block.timestamp + NORMAL_DELAY);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(add);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAvanaTimelockErrors.InvalidShortDelaySelector.selector, address(parameterStore), loosen
            )
        );
        timelock.executeBatch(t, v, p, bytes32(0), SALT);
        // Disabling an eligible pair always works, and re-enabling it works.
        bytes4 cap = IParameterStoreTighten.tightenMarketUsdCap.selector;
        _run(
            _self(
                abi.encodeCall(IAvanaTimelockGovernance.setShortDelaySelector, (address(parameterStore), cap, false))
            ),
            SALT
        );
        assertFalse(timelock.isShortDelaySelector(address(parameterStore), cap));
        assertTrue(timelock.isShortEligible(address(parameterStore), cap), "eligibility is immutable");
        assertEq(_required(_one(_tighten().target, _tighten().data)), NORMAL_DELAY);
        _run(
            _self(abi.encodeCall(IAvanaTimelockGovernance.setShortDelaySelector, (address(parameterStore), cap, true))),
            keccak256("on")
        );
        assertEq(_required(_one(_tighten().target, _tighten().data)), SHORT_DELAY);
    }

    // TEST-194 verifies: REQ-ACCESS-030, REQ-ACCESS-017, REQ-ACCESS-125, REQ-ACCESS-114, REQ-ACCESS-067
    function test_TEST_194_updateDelayAlwaysReverts() public {
        vm.expectRevert(IAvanaTimelockErrors.UpdateDelayDisabled.selector);
        timelock.updateDelay(0);
        TimelockFixture.Call[] memory calls = _self(abi.encodeCall(TimelockController.updateDelay, (1)));
        _schedule(governanceMultisig, calls, NORMAL_DELAY, SALT);
        vm.warp(block.timestamp + NORMAL_DELAY);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.expectRevert(IAvanaTimelockErrors.UpdateDelayDisabled.selector);
        timelock.executeBatch(t, v, p, bytes32(0), SALT);
        assertEq(timelock.getMinDelay(), SHORT_DELAY);
    }

    // ─── Roles on the timelock (REQ-ACCESS-028, REQ-ACCESS-153) ───

    // TEST-242 verifies: REQ-ACCESS-153, REQ-ACCESS-168, REQ-ACCESS-028, INV-084, Q-259
    function testFuzz_TEST_242_adminOnlyToItself(
        address a
    ) public {
        vm.assume(a != address(timelock));
        bytes32 admin = timelock.DEFAULT_ADMIN_ROLE();
        TimelockFixture.Call[] memory calls = _self(abi.encodeCall(IAccessControl.grantRole, (admin, a)));
        _schedule(governanceMultisig, calls, NORMAL_DELAY, SALT);
        vm.warp(block.timestamp + NORMAL_DELAY);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.AdminRoleOnlyTimelock.selector, admin, a));
        timelock.executeBatch(t, v, p, bytes32(0), SALT);
        assertFalse(timelock.hasRole(admin, a));
    }

    // TEST-242 verifies: REQ-ACCESS-028, REQ-ACCESS-019, REQ-ACCESS-024
    function test_TEST_242_roleChangesOnlyThroughOperations() public {
        bytes32 admin = timelock.DEFAULT_ADMIN_ROLE();
        vm.prank(governanceMultisig);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, governanceMultisig, admin)
        );
        timelock.grantRole(PROPOSER, bob);
        TimelockFixture.Call[] memory grant = _self(abi.encodeCall(IAccessControl.grantRole, (PROPOSER, bob)));
        assertEq(_required(grant), NORMAL_DELAY, "role changes are never short");
        bytes32 id = _schedule(governanceMultisig, grant, NORMAL_DELAY, SALT);
        assertTrue(timelock.isRoleChangeOperation(id));
        vm.warp(block.timestamp + NORMAL_DELAY);
        _execute(attacker, grant, SALT);
        assertTrue(timelock.hasRole(PROPOSER, bob));
    }
}
