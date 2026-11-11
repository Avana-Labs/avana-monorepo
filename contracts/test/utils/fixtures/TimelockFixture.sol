// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../../src/governance/roles/AvanaRoles.sol";
import {AvanaTimelock} from "../../../src/governance/timelock/AvanaTimelock.sol";
import {SelectorPair} from "../../../src/governance/timelock/types/SelectorPair.sol";
import {AvanaTest} from "../AvanaTest.sol";
import {CallRecorder} from "../mocks/CallRecorder.sol";
import {TimelockLaunchLists} from "./TimelockLaunchLists.sol";

/// @title TimelockFixture
/// @notice Deploys the AvanaTimelock with the launch configuration of `REQ-ACCESS-027`: `admin = address(0)`,
/// proposers the governance multisig and the Aave governance executor, executor the governance multisig, cancellers
/// the four of the role table, the Aave governance executor as DAO canceller, `normalDelay = 432,000`, public
/// execution on, and the launch short-delay list and DAO-only cancel set for the ParameterStore, MarketRegistry and
/// LPVaultSwap. The three targets are `CallRecorder`s that accept and record every call.
abstract contract TimelockFixture is AvanaTest {
    AvanaTimelock internal timelock;
    CallRecorder internal parameterStore;
    CallRecorder internal marketRegistry;
    CallRecorder internal lpVaultSwap;
    CallRecorder internal other;

    struct Call {
        address target;
        bytes data;
    }

    function _deployTimelock() internal {
        parameterStore = new CallRecorder();
        marketRegistry = new CallRecorder();
        lpVaultSwap = new CallRecorder();
        other = new CallRecorder();
        vm.label(address(parameterStore), "ParameterStore");
        vm.label(address(marketRegistry), "MarketRegistry");
        vm.label(address(lpVaultSwap), "LPVaultSwap");
        vm.label(address(other), "OtherTarget");
        timelock = _newTimelock(
            NORMAL_DELAY,
            true,
            TimelockLaunchLists.shortEligible(address(parameterStore), address(marketRegistry), address(lpVaultSwap)),
            TimelockLaunchLists.daoOnlyCancel(address(marketRegistry), address(lpVaultSwap))
        );
        vm.label(address(timelock), "AvanaTimelock");
    }

    function _newTimelock(
        uint256 normalDelay,
        bool publicExecution,
        SelectorPair[] memory shortEligible,
        SelectorPair[] memory daoOnly
    ) internal returns (AvanaTimelock) {
        address[] memory proposers = new address[](2);
        (proposers[0], proposers[1]) = (governanceMultisig, aaveGovernanceExecutor);
        address[] memory executors = new address[](1);
        executors[0] = governanceMultisig;
        address[] memory cancellers = new address[](2);
        (cancellers[0], cancellers[1]) = (emergencyGuardian, aaveGuardian);
        address[] memory daoCancellers = new address[](1);
        daoCancellers[0] = aaveGovernanceExecutor;
        return new AvanaTimelock(
            proposers, executors, cancellers, daoCancellers, normalDelay, publicExecution, shortEligible, daoOnly
        );
    }

    // ─── Operation helpers ───

    function _one(
        address target,
        bytes memory data
    ) internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(target, data);
    }

    function _two(
        Call memory a,
        Call memory b
    ) internal pure returns (Call[] memory calls) {
        calls = new Call[](2);
        (calls[0], calls[1]) = (a, b);
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

    function _id(
        Call[] memory calls,
        bytes32 salt
    ) internal view returns (bytes32) {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        return timelock.hashOperationBatch(t, v, p, bytes32(0), salt);
    }

    function _required(
        Call[] memory calls
    ) internal view returns (uint256) {
        (address[] memory t,, bytes[] memory p) = _arrays(calls);
        return timelock.requiredDelay(t, p);
    }

    function _schedule(
        address proposer,
        Call[] memory calls,
        uint256 delay,
        bytes32 salt
    ) internal returns (bytes32) {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.prank(proposer);
        timelock.scheduleBatch(t, v, p, bytes32(0), salt, delay);
        return timelock.hashOperationBatch(t, v, p, bytes32(0), salt);
    }

    function _execute(
        address executor,
        Call[] memory calls,
        bytes32 salt
    ) internal {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.prank(executor);
        timelock.executeBatch(t, v, p, bytes32(0), salt);
    }

    /// @notice Schedules at the required delay, waits it, and executes through the public path.
    function _run(
        Call[] memory calls,
        bytes32 salt
    ) internal returns (bytes32 id) {
        uint256 delay = _required(calls);
        id = _schedule(governanceMultisig, calls, delay, salt);
        vm.warp(block.timestamp + delay);
        _execute(attacker, calls, salt);
    }

    function _self(
        bytes memory data
    ) internal view returns (Call[] memory) {
        return _one(address(timelock), data);
    }

    function _daoCanceller() internal pure returns (bytes32) {
        return AvanaRoles.DAO_CANCELLER_ROLE;
    }
}
