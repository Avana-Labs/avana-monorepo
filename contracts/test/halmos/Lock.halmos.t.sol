// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILock} from "../../src/lock/lock/ILock.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {Test} from "forge-std/Test.sol";

/// @title LockHalmosTest
/// @notice Symbolic checks of the Lock's rules for every caller and every order of two calls: only the two members
/// acquire, only a free lock is acquired, only the holder releases, and nothing else moves the holder.
/// @dev The members are fixed concrete addresses; callers are symbolic. A Halmos run is one transaction, so the lock
/// state carries across the calls of one check as it does inside one Avana call tree.
contract LockHalmosTest is Test {
    address internal constant ADAPTER = address(0xADA9);
    address internal constant SWAP = address(0x5A9);

    Lock internal lock;

    function setUp() public {
        lock = new Lock(ADAPTER, SWAP);
    }

    // PROP-037 verifies: INV-054, Q-148, Q-223
    /// @notice For every caller and prior state: a member takes a free lock (never reverts), and every refusal carries
    /// the error of the first check that fails (NotMember before LockHeld).
    function check_PROP_037_acquireOnlyByMembersWhileFree(
        address caller,
        bool preHeld,
        bool preBySwap
    ) public {
        if (preHeld) {
            vm.prank(preBySwap ? SWAP : ADAPTER);
            lock.acquire();
        }
        address before = lock.holder();
        bool member = caller == ADAPTER || caller == SWAP;
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(lock).call(abi.encodeCall(ILock.acquire, ()));
        if (ok) {
            assert(before == address(0) && member);
            assert(lock.holder() == caller && lock.isLocked());
        } else {
            assert(lock.holder() == before);
            if (!member) {
                assert(keccak256(ret) == keccak256(abi.encodeWithSelector(ILock.NotMember.selector, caller)));
            } else {
                assert(before != address(0));
                assert(keccak256(ret) == keccak256(abi.encodeWithSelector(ILock.LockHeld.selector, before)));
            }
        }
    }

    // PROP-037 verifies: INV-054, Q-148, Q-223
    function check_PROP_037_releaseOnlyByHolder(
        address caller,
        bool preHeld,
        bool preBySwap
    ) public {
        if (preHeld) {
            vm.prank(preBySwap ? SWAP : ADAPTER);
            lock.acquire();
        }
        address before = lock.holder();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(lock).call(abi.encodeCall(ILock.release, ()));
        if (ok) {
            assert(before == caller && before != address(0));
            assert(lock.holder() == address(0) && !lock.isLocked());
        } else {
            assert(before != caller || before == address(0));
            assert(lock.holder() == before);
            assert(keccak256(ret) == keccak256(abi.encodeWithSelector(ILock.NotHolder.selector, caller)));
        }
    }

    // PROP-037 verifies: INV-054, Q-148, Q-223
    function check_PROP_037_secondAcquireFails(
        address first,
        address second
    ) public {
        vm.prank(first);
        try lock.acquire() {
            vm.prank(second);
            try lock.acquire() {
                assert(false);
            } catch {}
        } catch {}
    }

    // PROP-037 verifies: INV-054, Q-148, Q-223
    /// @notice No call other than `acquire` and `release` changes the holder, whatever its selector and arguments.
    function check_PROP_037_holderChangesOnlyThroughAcquireAndRelease(
        address caller,
        bytes4 selector,
        bytes32 arg
    ) public {
        vm.assume(selector != ILock.acquire.selector && selector != ILock.release.selector);
        vm.prank(ADAPTER);
        lock.acquire();
        vm.prank(caller);
        (bool ok,) = address(lock).call(abi.encodePacked(selector, arg));
        ok;
        assert(lock.holder() == ADAPTER);
    }

    // PROP-075 verifies: INV-091, INV-054
    function check_PROP_075_membersFixedDistinctAndSet() public view {
        assert(lock.AAVE_ADAPTER() == ADAPTER && lock.LP_VAULT_SWAP() == SWAP);
        assert(lock.AAVE_ADAPTER() != address(0) && lock.LP_VAULT_SWAP() != address(0));
        assert(lock.AAVE_ADAPTER() != lock.LP_VAULT_SWAP());
        assert(lock.SELF() == address(lock));
    }

    // PROP-075 verifies: INV-091
    function check_PROP_075_constructorRefusesInvalidMembers(
        address a,
        address b
    ) public {
        try new Lock(a, b) returns (Lock deployed) {
            assert(a != address(0) && b != address(0) && a != b);
            assert(deployed.AAVE_ADAPTER() == a && deployed.LP_VAULT_SWAP() == b);
        } catch {
            assert(a == address(0) || b == address(0) || a == b);
        }
    }
}
