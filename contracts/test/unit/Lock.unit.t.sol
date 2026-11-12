// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILock} from "../../src/lock/lock/ILock.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {LockSlot} from "../../src/lock/lock/LockSlot.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {LockDelegator, LockHoldingReader, LockMember} from "../utils/mocks/LockMember.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LockUnitTest
/// @notice The Lock on its own (2.16): two fixed members, no nesting, release by the holder only, delegatecall refused,
/// transient state that a revert rolls back and a new transaction clears, constant cost with no storage or external
/// access.
/// @dev Lock-side part of TEST-060 and TEST-270. The callee-side checks (Collateralization, every LPVault, the Adapter's
/// inner calls, routes, escrow) and the no-redeploy listing flow join these rows with the contracts that make them.
/// Foundry 1.9 runs each top-level call of a test as its own transaction (`isolate = true` by default). This suite
/// turns isolation off so the calls of one test share a transaction, as the calls of one Avana call tree do;
/// `LockTransactionUnitTest` keeps it on to show the lock is free again in the next transaction.
/// forge-config: default.isolate = false
contract LockUnitTest is AvanaTest {
    /// @notice Warm gas of `acquire` + `release` measured by `_cycleGas` (solc 0.8.28, optimizer 10,000 runs).
    uint256 internal constant ADAPTER_CYCLE_GAS = 2387;
    uint256 internal constant SWAP_CYCLE_GAS = 2406;

    Lock internal lock;
    LockMember internal adapter;
    LockMember internal lpVaultSwap;
    LockMember internal outsider;
    LockDelegator internal delegator;

    function setUp() public {
        adapter = new LockMember();
        lpVaultSwap = new LockMember();
        outsider = new LockMember();
        delegator = new LockDelegator();
        lock = new Lock(address(adapter), address(lpVaultSwap));
        adapter.setLock(lock);
        lpVaultSwap.setLock(lock);
        outsider.setLock(lock);
        vm.label(address(lock), "Lock");
        vm.label(address(adapter), "AaveAdapter");
        vm.label(address(lpVaultSwap), "LPVaultSwap");
        vm.label(address(outsider), "Outsider");
    }

    // ─── Construction ───

    // TEST-270 verifies: REQ-LOCK-001, REQ-LOCK-024, INV-091, Q-148, Q-318
    // Sources: 5.1 TEST-270 (Lock side), 2.16
    function test_TEST_270_membersAndSelfFixedAtConstruction() public view {
        assertEq(lock.AAVE_ADAPTER(), address(adapter), "AAVE_ADAPTER");
        assertEq(lock.LP_VAULT_SWAP(), address(lpVaultSwap), "LP_VAULT_SWAP");
        assertEq(lock.SELF(), address(lock), "SELF");
        assertEq(lock.holder(), address(0), "free after deployment");
        assertFalse(lock.isLocked(), "not locked after deployment");
    }

    // TEST-270 verifies: REQ-LOCK-029, INV-091
    function testFuzz_TEST_270_constructorRefusesZeroOrEqualMembers(
        address a,
        address b
    ) public {
        vm.assume(a != address(0) && b != address(0) && a != b);
        vm.expectRevert(ILock.InvalidMembers.selector);
        new Lock(address(0), b);
        vm.expectRevert(ILock.InvalidMembers.selector);
        new Lock(a, address(0));
        vm.expectRevert(ILock.InvalidMembers.selector);
        new Lock(a, a);
        Lock ok = new Lock(a, b);
        assertEq(ok.AAVE_ADAPTER(), a);
        assertEq(ok.LP_VAULT_SWAP(), b);
    }

    /// @notice Members need no code at deployment: the Lock is deployed before both, at their predicted addresses.
    // TEST-270 verifies: REQ-LOCK-001, REQ-LOCK-029
    function test_TEST_270_membersNeedNoCodeAtDeployment() public {
        address predictedAdapter = makeAddr("predictedAdapter");
        address predictedSwap = makeAddr("predictedSwap");
        assertEq(predictedAdapter.code.length, 0);
        Lock early = new Lock(predictedAdapter, predictedSwap);
        vm.prank(predictedSwap);
        early.acquire();
        assertEq(early.holder(), predictedSwap);
    }

    // ─── acquire ───

    // TEST-060 verifies: REQ-LOCK-004, REQ-LOCK-006, REQ-LOCK-009, INV-054, Q-148
    // Sources: 5.1 TEST-060 (Lock side), 2.16
    function test_TEST_060_eachMemberAcquiresAFreeLock() public {
        adapter.acquire();
        assertEq(lock.holder(), address(adapter), "adapter holds");
        assertTrue(lock.isLocked(), "locked");
        adapter.release();
        lpVaultSwap.acquire();
        assertEq(lock.holder(), address(lpVaultSwap), "LPVaultSwap holds");
        lpVaultSwap.release();
        assertEq(lock.holder(), address(0), "free");
    }

    // TEST-270 verifies: REQ-LOCK-004, REQ-LOCK-019, REQ-LOCK-025, INV-091, Q-223
    function testFuzz_TEST_270_nonMemberCannotAcquire(
        address caller
    ) public {
        vm.assume(caller != address(adapter) && caller != address(lpVaultSwap));
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ILock.NotMember.selector, caller));
        lock.acquire();
        assertEq(lock.holder(), address(0));
    }

    // TEST-060 verifies: REQ-LOCK-005, REQ-LOCK-020, INV-054, Q-119, Q-148
    function test_TEST_060_heldLockRefusesEveryAcquire() public {
        adapter.acquire();
        // The holder itself: no nesting or re-entry.
        vm.expectRevert(abi.encodeWithSelector(ILock.LockHeld.selector, address(adapter)));
        adapter.acquire();
        // The other member.
        vm.expectRevert(abi.encodeWithSelector(ILock.LockHeld.selector, address(adapter)));
        lpVaultSwap.acquire();
        // A non-member is refused for its membership first.
        vm.expectRevert(abi.encodeWithSelector(ILock.NotMember.selector, address(outsider)));
        outsider.acquire();
        assertEq(lock.holder(), address(adapter), "holder unchanged");
    }

    /// @notice A second outer entry point started from inside a held call tree (a token hook, a route, a callback)
    /// reverts, whichever member holds the lock.
    // TEST-060 verifies: REQ-LOCK-005, REQ-LOCK-020, REQ-LOCK-026, INV-054, Q-148, Q-255
    function test_TEST_060_reentryFromInsideACallTreeReverts() public {
        (bool ok, bytes memory ret) =
            lpVaultSwap.acquireCallRelease(address(adapter), abi.encodeCall(LockMember.acquire, ()));
        assertFalse(ok, "inner acquire succeeded");
        assertEq(ret, abi.encodeWithSelector(ILock.LockHeld.selector, address(lpVaultSwap)));
        (ok, ret) = adapter.acquireCallRelease(address(lpVaultSwap), abi.encodeCall(LockMember.acquire, ()));
        assertFalse(ok, "inner acquire succeeded");
        assertEq(ret, abi.encodeWithSelector(ILock.LockHeld.selector, address(adapter)));
        assertEq(lock.holder(), address(0), "released after the outer call");
    }

    // ─── release ───

    // TEST-060 verifies: REQ-LOCK-008, REQ-LOCK-015, REQ-LOCK-021, Q-148
    function test_TEST_060_onlyTheHolderReleases() public {
        adapter.acquire();
        vm.expectRevert(abi.encodeWithSelector(ILock.NotHolder.selector, address(lpVaultSwap)));
        lpVaultSwap.release();
        vm.expectRevert(abi.encodeWithSelector(ILock.NotHolder.selector, address(outsider)));
        outsider.release();
        adapter.release();
        assertEq(lock.holder(), address(0));
        assertFalse(lock.isLocked());
    }

    // TEST-060 verifies: REQ-LOCK-008, REQ-LOCK-015, REQ-LOCK-021
    function testFuzz_TEST_060_strangerCannotReleaseAHeldLock(
        address caller,
        bool swapHolds
    ) public {
        LockMember holderMember = swapHolds ? lpVaultSwap : adapter;
        vm.assume(caller != address(holderMember));
        holderMember.acquire();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ILock.NotHolder.selector, caller));
        lock.release();
        assertEq(lock.holder(), address(holderMember));
    }

    // TEST-060 verifies: REQ-LOCK-008, REQ-LOCK-021
    function testFuzz_TEST_060_releaseOfAFreeLockReverts(
        address caller
    ) public {
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ILock.NotHolder.selector, caller));
        lock.release();
    }

    // ─── Transient state ───

    // TEST-060 verifies: REQ-LOCK-013, REQ-LOCK-020, Q-119, Q-148
    function test_TEST_060_revertRollsTheHolderBack() public {
        vm.expectRevert(LockMember.Boom.selector);
        adapter.acquireAndRevert();
        assertEq(lock.holder(), address(0), "revert left the lock held");
        lpVaultSwap.acquire();
        assertEq(lock.holder(), address(lpVaultSwap));
    }

    /// @notice An outer call that returns without releasing fails closed for the rest of its transaction.
    // TEST-060 verifies: REQ-LOCK-014, Q-148
    function test_TEST_060_unreleasedLockFailsClosedInSameTransaction() public {
        adapter.acquire();
        vm.expectRevert(abi.encodeWithSelector(ILock.LockHeld.selector, address(adapter)));
        lpVaultSwap.acquire();
    }

    /// @notice The holder lives in transient storage only: no persistent slot of the Lock is ever written or read.
    // TEST-060 verifies: REQ-LOCK-002, REQ-LOCK-018, Q-119
    function test_TEST_060_noPersistentStorageAccess() public {
        vm.record();
        adapter.acquire();
        lock.holder();
        lock.isLocked();
        adapter.release();
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(lock));
        assertEq(reads.length, 0, "storage read");
        assertEq(writes.length, 0, "storage write");
    }

    /// @notice `acquire` and `release` call no other contract.
    // TEST-060 verifies: REQ-LOCK-018, REQ-LOCK-024, REQ-LOCK-027
    function test_TEST_060_acquireAndReleaseMakeNoExternalCall() public {
        vm.startStateDiffRecording();
        vm.prank(address(adapter));
        lock.acquire();
        vm.prank(address(adapter));
        lock.release();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertGt(accesses.length, 0, "nothing recorded");
        for (uint256 i; i < accesses.length; ++i) {
            // Every call or account access the Lock itself made would name it as the accessor.
            assertNotEq(accesses[i].accessor, address(lock), "the Lock called or touched another account");
        }
    }

    /// @notice The cost of `acquire` and `release` does not depend on what was locked before; the two members differ
    /// only by the second member comparison.
    // TEST-060 verifies: REQ-LOCK-018, Q-318
    function test_TEST_060_constantGas() public {
        // The first call of a transaction pays the cold account access; the Lock's own cost is what repeats.
        _cycleGas(address(adapter));
        uint256 byAdapter = _cycleGas(address(adapter));
        uint256 bySwap = _cycleGas(address(lpVaultSwap));
        uint256 again = _cycleGas(address(adapter));
        assertEq(byAdapter, again, "gas differs by history");
        assertEq(bySwap, _cycleGas(address(lpVaultSwap)), "gas differs by history");
        assertLe(bySwap - byAdapter, 30, "more than one extra comparison");
    }

    // ─── Delegatecall and surface ───

    // TEST-060 verifies: REQ-LOCK-003, REQ-LOCK-022, Q-148
    function test_TEST_060_everyFunctionRefusesDelegatecall() public {
        bytes[7] memory calls = [
            abi.encodeCall(ILock.acquire, ()),
            abi.encodeCall(ILock.release, ()),
            abi.encodeCall(ILock.holder, ()),
            abi.encodeCall(ILock.isLocked, ()),
            abi.encodeCall(ILock.AAVE_ADAPTER, ()),
            abi.encodeCall(ILock.LP_VAULT_SWAP, ()),
            abi.encodeCall(ILock.SELF, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = delegator.delegate(address(lock), calls[i]);
            assertFalse(ok, "delegatecall accepted");
            assertEq(ret, abi.encodeWithSelector(ILock.DelegateCallNotAllowed.selector));
        }
    }

    /// @notice The Lock has no function besides the seven of ILock: no owner, setter, pause, upgrade or fallback.
    // TEST-270 verifies: REQ-LOCK-001, REQ-LOCK-015, REQ-LOCK-024, REQ-ACCESS-066
    function testFuzz_TEST_270_noOtherEntryPoint(
        bytes4 selector,
        bytes calldata tail,
        address caller
    ) public {
        vm.assume(
            selector != ILock.acquire.selector && selector != ILock.release.selector
                && selector != ILock.holder.selector && selector != ILock.isLocked.selector
                && selector != ILock.AAVE_ADAPTER.selector && selector != ILock.LP_VAULT_SWAP.selector
                && selector != ILock.SELF.selector
        );
        adapter.acquire();
        vm.prank(caller);
        (bool ok,) = address(lock).call(abi.encodePacked(selector, tail));
        assertFalse(ok, "unknown selector accepted");
        assertEq(lock.holder(), address(adapter), "holder changed outside acquire and release");
    }

    /// @notice A call carrying ETH reverts with empty data before any check, directly or through a payable
    /// delegatecall frame, and writes nothing.
    // TEST-060 verifies: REQ-LOCK-003, REQ-LOCK-022, REQ-LOCK-001
    function test_TEST_060_valueCallsRevertEmptyAndWriteNothing() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory ret) = delegator.delegate{value: 1}(address(lock), abi.encodeCall(ILock.acquire, ()));
        assertFalse(ok, "delegatecall with value accepted");
        assertEq(ret.length, 0, "revert data");
        vm.deal(address(outsider), 1 ether);
        vm.prank(address(outsider));
        (ok, ret) = address(lock).call{value: 1}(abi.encodeCall(ILock.acquire, ()));
        assertFalse(ok);
        assertEq(ret.length, 0, "revert data");
        (ok,) = address(lock).call{value: 1}(abi.encodeCall(ILock.holder, ()));
        assertFalse(ok, "payable view");
        assertEq(lock.holder(), address(0));
    }

    /// @notice Under STATICCALL a member's `acquire` cannot write the slot and fails; the views answer.
    // TEST-060 verifies: REQ-LOCK-002, REQ-LOCK-009
    function test_TEST_060_staticcallCannotAcquire() public {
        vm.prank(address(adapter));
        (bool ok,) = address(lock).staticcall(abi.encodeCall(ILock.acquire, ()));
        assertFalse(ok, "acquire under staticcall");
        assertEq(lock.holder(), address(0));
        (bool viewOk, bytes memory ret) = delegator.staticProbe(address(lock), abi.encodeCall(ILock.isLocked, ()));
        assertTrue(viewOk);
        assertFalse(abi.decode(ret, (bool)));
    }

    /// @notice Inner callees read the holder with a view call while it is held; they see the member that holds it.
    // TEST-060 verifies: REQ-LOCK-009, REQ-LOCK-010
    function test_TEST_060_viewCalleeSeesTheHolder() public {
        LockHoldingReader reader = new LockHoldingReader();
        Lock readerLock = new Lock(address(reader), address(lpVaultSwap));
        reader.setLock(readerLock);
        (address seenHolder, bool seenLocked) = reader.acquireAndProbe(delegator);
        assertEq(seenHolder, address(reader), "holder seen by a view callee");
        assertTrue(seenLocked, "locked seen by a view callee");
        assertEq(readerLock.holder(), address(0));
    }

    /// @notice `address(0)` is neither a member nor ever a holder.
    // TEST-060 verifies: REQ-LOCK-004, REQ-LOCK-008, REQ-LOCK-021
    function test_TEST_060_zeroAddressCallerRefused() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(ILock.NotMember.selector, address(0)));
        lock.acquire();
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(ILock.NotHolder.selector, address(0)));
        lock.release();
        adapter.acquire();
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(ILock.NotHolder.selector, address(0)));
        lock.release();
    }

    /// @notice Exact warm cost of one acquire and release by each member, for the pinned compiler settings. Any change
    /// to the Lock's code paths (a second TLOAD, a storage read, an external call) changes these numbers; update them
    /// only with a review of the new bytecode.
    // TEST-060 verifies: REQ-LOCK-018
    function test_TEST_060_exactCycleCost() public {
        _cycleGas(address(adapter));
        assertEq(_cycleGas(address(adapter)), ADAPTER_CYCLE_GAS, "AaveAdapter cycle");
        assertEq(_cycleGas(address(lpVaultSwap)), SWAP_CYCLE_GAS, "LPVaultSwap cycle");
    }

    // TEST-270 verifies: REQ-LOCK-001
    function test_TEST_270_refusesEther() public {
        vm.deal(address(adapter), 1 ether);
        vm.prank(address(adapter));
        (bool ok,) = address(lock).call{value: 1}(abi.encodeCall(ILock.acquire, ()));
        assertFalse(ok, "acquire accepted ether");
        (ok,) = address(lock).call{value: 1}("");
        assertFalse(ok, "plain transfer accepted");
    }

    // TEST-060 verifies: REQ-LOCK-009
    function testFuzz_TEST_060_isLockedMatchesHolder(
        uint8 steps,
        uint256 seed
    ) public {
        steps = uint8(bound(steps, 1, 24));
        for (uint256 i; i < steps; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i))) % 4;
            if (r == 0) {
                try adapter.acquire() {} catch {}
            } else if (r == 1) {
                try lpVaultSwap.acquire() {} catch {}
            } else if (r == 2) {
                try adapter.release() {} catch {}
            } else {
                try lpVaultSwap.release() {} catch {}
            }
            address h = lock.holder();
            assertEq(lock.isLocked(), h != address(0));
            assertTrue(h == address(0) || h == address(adapter) || h == address(lpVaultSwap), "foreign holder");
        }
    }

    function _cycleGas(
        address member
    ) private returns (uint256 used) {
        vm.prank(member);
        uint256 start = gasleft();
        lock.acquire();
        vm.prank(member);
        lock.release();
        used = start - gasleft();
    }
}

/// @title LockTransactionUnitTest
/// @notice With isolation on (set here explicitly; it is also the Foundry 1.9 default), every top-level call is a
/// transaction of its own: a lock left held by one outer call is free at the start of the next.
/// forge-config: default.isolate = true
contract LockTransactionUnitTest is AvanaTest {
    Lock internal lock;
    LockMember internal adapter;
    LockMember internal lpVaultSwap;

    function setUp() public {
        adapter = new LockMember();
        lpVaultSwap = new LockMember();
        lock = new Lock(address(adapter), address(lpVaultSwap));
        adapter.setLock(lock);
        lpVaultSwap.setLock(lock);
    }

    /// @notice Each top-level call is its own transaction here, so a lock left held by one is free in the next.
    // TEST-060 verifies: REQ-LOCK-002, REQ-LOCK-012, REQ-LOCK-014, Q-075, Q-148
    function test_TEST_060_lockIsFreeAtTheStartOfEveryTransaction() public {
        adapter.acquire();
        assertEq(lock.holder(), address(0), "a lock outlived its transaction");
        lpVaultSwap.acquire();
        assertEq(lock.holder(), address(0));
        assertEq(vm.load(address(lock), LockSlot.HOLDER_SLOT), bytes32(0), "persistent slot written");
    }
}
