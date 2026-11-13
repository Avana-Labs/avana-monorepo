// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {AvanaTimelock} from "../../src/governance/timelock/AvanaTimelock.sol";
import {IAvanaTimelockGovernance} from "../../src/governance/timelock/IAvanaTimelockGovernance.sol";
import {GovernedTargets} from "../../src/governance/timelock/types/GovernedTargets.sol";
import {SelectorPair} from "../../src/governance/timelock/types/SelectorPair.sol";
import {ILPVaultSwapAdmin} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapAdmin.sol";
import {IMarketRegistryRoutes} from "../../src/policy/market-registry/IMarketRegistryRoutes.sol";
import {TimelockLaunchLists} from "../utils/fixtures/TimelockLaunchLists.sol";
import {CallRecorder} from "../utils/mocks/CallRecorder.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

/// @title AvanaTimelockHalmosTest
/// @notice Symbolic checks of the AvanaTimelock for every caller, selector and delay: the required delay is the short
/// delay only when every call is listed, the normal delay stays inside its bounds and changes only by self-call,
/// `updateDelay` never succeeds, the short list stays inside `SHORT_ELIGIBLE`, the admin role goes only to the
/// timelock, and cancel rights follow SPEC-GOV-005.
contract AvanaTimelockHalmosTest is Test {
    uint256 internal constant SHORT_DELAY = 43_200;
    uint256 internal constant NORMAL_DELAY = 432_000;
    uint256 internal constant MIN_NORMAL_DELAY = 345_600;
    uint256 internal constant GRACE_PERIOD = 1_209_600;
    // Fixed actors: Halmos runs no `makeAddr`.
    address internal constant MULTISIG = address(0xA11);
    address internal constant EXECUTOR_DAO = address(0xDA0);
    address internal constant GUARDIAN = address(0x6A1);
    address internal constant AAVE_GUARDIAN = address(0x6A2);

    AvanaTimelock internal timelock;
    CallRecorder internal parameterStore;
    CallRecorder internal marketRegistry;
    CallRecorder internal lpVaultSwap;
    CallRecorder internal other;

    struct Call {
        address target;
        bytes data;
    }

    function setUp() public {
        parameterStore = new CallRecorder();
        marketRegistry = new CallRecorder();
        lpVaultSwap = new CallRecorder();
        other = new CallRecorder();
        address[] memory proposers = new address[](2);
        (proposers[0], proposers[1]) = (MULTISIG, EXECUTOR_DAO);
        address[] memory executors = new address[](1);
        executors[0] = MULTISIG;
        address[] memory cancellers = new address[](2);
        (cancellers[0], cancellers[1]) = (GUARDIAN, AAVE_GUARDIAN);
        address[] memory dao = new address[](1);
        dao[0] = EXECUTOR_DAO;
        SelectorPair[] memory shortList =
            TimelockLaunchLists.shortEligible(address(parameterStore), address(marketRegistry), address(lpVaultSwap));
        SelectorPair[] memory daoList = TimelockLaunchLists.daoOnlyCancel(address(marketRegistry), address(lpVaultSwap));
        timelock = new AvanaTimelock(
            proposers,
            executors,
            cancellers,
            dao,
            NORMAL_DELAY,
            true,
            shortList,
            daoList,
            GovernedTargets(address(parameterStore), address(marketRegistry), address(lpVaultSwap))
        );
    }

    function _one(
        address target,
        bytes memory data
    ) internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(target, data);
    }

    function _arrays(
        Call[] memory calls
    ) internal pure returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads) {
        targets = new address[](calls.length);
        values = new uint256[](calls.length);
        payloads = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            targets[i] = calls[i].target;
            payloads[i] = calls[i].data;
        }
    }

    function _schedule(
        Call[] memory calls,
        uint256 delay
    ) internal returns (bytes32) {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.prank(MULTISIG);
        timelock.scheduleBatch(t, v, p, bytes32(0), bytes32(0), delay);
        return timelock.hashOperationBatch(t, v, p, bytes32(0), bytes32(0));
    }

    // PROP-058 verifies: INV-068, Q-228, Q-262
    function check_PROP_058_requiredDelayIsShortOrNormal(
        address t0,
        bytes4 s0,
        address t1,
        bytes4 s1,
        bool two
    ) public view {
        address[] memory targets = new address[](two ? 2 : 1);
        bytes[] memory payloads = new bytes[](two ? 2 : 1);
        targets[0] = t0;
        payloads[0] = abi.encodePacked(s0, uint256(1));
        if (two) {
            targets[1] = t1;
            payloads[1] = abi.encodePacked(s1, uint256(2));
        }
        uint256 r = timelock.requiredDelay(targets, payloads);
        bool allListed = timelock.isShortDelaySelector(t0, s0) && (!two || timelock.isShortDelaySelector(t1, s1));
        assert(r == (allListed ? SHORT_DELAY : timelock.normalDelay()));
    }

    // PROP-058 verifies: INV-051, INV-068, Q-226
    function check_PROP_058_setNormalDelayOnlySelfAndBounded(
        address caller,
        uint256 d
    ) public {
        vm.prank(caller);
        try timelock.setNormalDelay(d) {
            assert(caller == address(timelock));
            assert(d >= MIN_NORMAL_DELAY && d <= NORMAL_DELAY);
            assert(timelock.normalDelay() == d);
        } catch {
            assert(timelock.normalDelay() == NORMAL_DELAY);
        }
    }

    // PROP-058 verifies: INV-051, INV-068, Q-226
    function check_PROP_058_updateDelayNeverSucceeds(
        address caller,
        uint256 d
    ) public {
        vm.prank(caller);
        try timelock.updateDelay(d) {
            assert(false);
        } catch {}
        assert(timelock.getMinDelay() == SHORT_DELAY);
    }

    // PROP-073 verifies: INV-068, INV-090, Q-262
    function check_PROP_073_shortListStaysWithinEligible(
        address target,
        bytes4 selector,
        bool enabled
    ) public {
        vm.prank(address(timelock));
        try timelock.setShortDelaySelector(target, selector, enabled) {} catch {}
        assert(!timelock.isShortDelaySelector(target, selector) || timelock.isShortEligible(target, selector));
    }

    // PROP-070 verifies: INV-084, Q-259
    function check_PROP_070_adminOnlyToTheTimelock(
        address a
    ) public {
        bytes32 admin = timelock.DEFAULT_ADMIN_ROLE();
        vm.prank(address(timelock));
        try timelock.grantRole(admin, a) {
            assert(a == address(timelock));
        } catch {
            assert(!timelock.hasRole(admin, a) || a == address(timelock));
        }
    }

    // PROP-058 verifies: INV-051, INV-068, Q-263
    // PROP-073 verifies: INV-068, INV-090, Q-263
    function check_PROP_058_cancelRights(
        uint8 kind,
        address caller
    ) public {
        Call[] memory calls;
        uint256 delay = NORMAL_DELAY;
        if (kind % 3 == 0) {
            calls = _one(address(other), abi.encodeCall(IAccessControl.grantRole, (keccak256("R"), address(2))));
        } else if (kind % 3 == 1) {
            calls = _one(address(lpVaultSwap), abi.encodeWithSelector(ILPVaultSwapAdmin.addKeeper.selector, address(3)));
        } else {
            calls =
                _one(address(marketRegistry), abi.encodeWithSelector(IMarketRegistryRoutes.disableRoute.selector, 7));
            delay = SHORT_DELAY;
        }
        bytes32 id = _schedule(calls, delay);
        bool restricted = timelock.isRoleChangeOperation(id) || timelock.isRestoringOperation(id);
        vm.prank(caller);
        try timelock.cancel(id) {
            assert(timelock.hasRole(timelock.CANCELLER_ROLE(), caller));
            assert(!restricted || timelock.hasRole(AvanaRoles.DAO_CANCELLER_ROLE, caller));
            assert(!timelock.isOperation(id));
        } catch {
            assert(timelock.isOperationPending(id));
        }
    }

    // PROP-058 verifies: INV-051, INV-068, SPEC-GOV-013, Q-228
    function check_PROP_058_executeWindow(
        uint256 wait,
        address caller
    ) public {
        Call[] memory calls =
            _one(address(timelock), abi.encodeCall(IAvanaTimelockGovernance.setNormalDelay, (MIN_NORMAL_DELAY)));
        bytes32 id = _schedule(calls, NORMAL_DELAY);
        uint256 readyAt = timelock.getTimestamp(id);
        vm.assume(wait < 60 days);
        vm.warp(block.timestamp + wait);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.prank(caller);
        try timelock.executeBatch(t, v, p, bytes32(0), bytes32(0)) {
            assert(block.timestamp >= readyAt && block.timestamp < readyAt + GRACE_PERIOD);
            assert(timelock.normalDelay() == MIN_NORMAL_DELAY);
        } catch {
            assert(block.timestamp < readyAt || block.timestamp >= readyAt + GRACE_PERIOD);
        }
    }
}
