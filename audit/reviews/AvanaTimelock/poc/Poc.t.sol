// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {TimelockFixture} from "./utils/fixtures/TimelockFixture.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAvanaTimelockGovernance} from "../src/governance/timelock/IAvanaTimelockGovernance.sol";
import {IAvanaTimelockErrors} from "../src/governance/timelock/IAvanaTimelockErrors.sol";

contract Reenter {
    function cleanup(address tl, bytes32 id) external { IAvanaTimelockGovernance(tl).cleanupExpiredOperation(id); }
}

contract Poc is TimelockFixture {
    function setUp() public { vm.warp(1_780_000_000); _deployTimelock(); }

    // 1: role-change op turns public execution off; guardian cannot cancel it.
    function test_revokeOpenExecutorIsDaoOnly() public {
        bytes32 EX = timelock.EXECUTOR_ROLE();
        Call[] memory c = _self(abi.encodeCall(IAccessControl.revokeRole, (EX, address(0))));
        bytes32 id = _schedule(governanceMultisig, c, NORMAL_DELAY, bytes32(0));
        assertTrue(timelock.isRoleChangeOperation(id));
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.RoleChangeCancelRestricted.selector, id));
        timelock.cancel(id);
        vm.warp(block.timestamp + NORMAL_DELAY);
        _execute(attacker, c, bytes32(0));
        assertFalse(timelock.publicExecution());
        // a DAO-proposed op now needs the multisig to execute
        Call[] memory d = _one(address(other), hex"aabbccdd");
        _schedule(aaveGovernanceExecutor, d, NORMAL_DELAY, bytes32(0));
        vm.warp(block.timestamp + NORMAL_DELAY);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(d);
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.ExecutionNotPublic.selector, aaveGovernanceExecutor));
        timelock.executeBatch(t, v, p, bytes32(0), bytes32(0));
    }

    // 2: timelock can revoke its own DEFAULT_ADMIN_ROLE.
    function test_selfAdminRevocable() public {
        bytes32 A = timelock.DEFAULT_ADMIN_ROLE();
        _run(_self(abi.encodeCall(IAccessControl.revokeRole, (A, address(timelock)))), bytes32(0));
        assertFalse(timelock.hasRole(A, address(timelock)));
    }

    // 3: isOperationExpired panics for huge readyAt.
    function test_expiredViewOverflow() public {
        Call[] memory c = _one(address(other), hex"aabbccdd");
        bytes32 id = _schedule(governanceMultisig, c, type(uint256).max - block.timestamp, bytes32(0));
        vm.expectRevert(); // panic 0x11
        timelock.isOperationExpired(id);
        vm.expectRevert();
        timelock.cleanupExpiredOperation(id);
    }

    // 4: executed op cleans another expired op (CVL expiredOperationOnlyCleanedUp counterexample)
    function test_executeCleansOther() public {
        Call[] memory a = _one(address(other), hex"01020304");
        bytes32 idA = _schedule(governanceMultisig, a, NORMAL_DELAY, bytes32(0));
        Call[] memory b = _self(abi.encodeCall(IAvanaTimelockGovernance.cleanupExpiredOperation, (idA)));
        vm.warp(block.timestamp + GRACE_PERIOD);
        _schedule(governanceMultisig, b, NORMAL_DELAY, bytes32(0));
        vm.warp(block.timestamp + NORMAL_DELAY);
        assertTrue(timelock.isOperationExpired(idA));
        _execute(attacker, b, bytes32(0));
        assertEq(timelock.getTimestamp(idA), 0);
    }

    // 5: four-byte payload on a listed pair is short; three bytes is not.
    function test_fourBytes() public view {
        bytes4 sel = bytes4(keccak256("removeKeeper(address)"));
        assertEq(_required(_one(address(lpVaultSwap), abi.encodePacked(sel))), SHORT_DELAY);
    }
}
