// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILock} from "../../../src/lock/lock/ILock.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {LockMember} from "../../utils/mocks/LockMember.sol";

/// @title LockProperties
/// @notice Echidna and Medusa properties of the Lock (2.16). Between transactions the lock is always free and its two
/// members are fixed, distinct and non-zero. Inside one transaction a member takes a free lock, nobody else takes or
/// frees it while it is held, a revert rolls it back, and the holder frees it.
/// @dev `property_` functions run in property mode; `memberCycle`, `outsiderAcquire`, `acquireWithoutRelease` and
/// `revertedOuterCall` run in
/// assertion mode, each a full sequence inside one transaction with finite branching for hevm.
contract LockProperties {
    Lock internal immutable LOCK;
    LockMember internal immutable ADAPTER;
    LockMember internal immutable SWAP;
    LockMember internal immutable OUTSIDER;

    /// @notice Number of assertion sequences run; written so each call is a transaction.
    uint256 public sequences;

    constructor() {
        ADAPTER = new LockMember();
        SWAP = new LockMember();
        OUTSIDER = new LockMember();
        LOCK = new Lock(address(ADAPTER), address(SWAP));
        ADAPTER.setLock(LOCK);
        SWAP.setLock(LOCK);
        OUTSIDER.setLock(LOCK);
    }

    // ─── Properties (between transactions) ───

    function property_freeAtTransactionStart() external view returns (bool) {
        return LOCK.holder() == address(0) && !LOCK.isLocked();
    }

    function property_membersFixedDistinctAndSet() external view returns (bool) {
        return LOCK.AAVE_ADAPTER() == address(ADAPTER) && LOCK.LP_VAULT_SWAP() == address(SWAP)
            && address(ADAPTER) != address(SWAP) && address(ADAPTER) != address(0) && LOCK.SELF() == address(LOCK);
    }

    // ─── Assertion entry points (inside one transaction) ───

    /// @notice One member takes the lock; the other member, the holder itself and an outsider cannot take it; nobody
    /// but the holder frees it; the holder frees it.
    function memberCycle(
        bool swapHolds
    ) external {
        LockMember holder = swapHolds ? SWAP : ADAPTER;
        LockMember other = swapHolds ? ADAPTER : SWAP;
        holder.acquire();
        assert(LOCK.holder() == address(holder) && LOCK.isLocked());
        try holder.acquire() {
            assert(false);
        } catch (bytes memory reason) {
            assert(keccak256(reason) == keccak256(abi.encodeWithSelector(ILock.LockHeld.selector, address(holder))));
        }
        try other.acquire() {
            assert(false);
        } catch (bytes memory reason) {
            assert(keccak256(reason) == keccak256(abi.encodeWithSelector(ILock.LockHeld.selector, address(holder))));
        }
        try OUTSIDER.acquire() {
            assert(false);
        } catch {}
        try other.release() {
            assert(false);
        } catch {}
        try OUTSIDER.release() {
            assert(false);
        } catch {}
        assert(LOCK.holder() == address(holder));
        holder.release();
        assert(LOCK.holder() == address(0) && !LOCK.isLocked());
        ++sequences;
    }

    /// @notice A contract outside the member set never takes the lock, held or free.
    function outsiderAcquire(
        bool preHeld
    ) external {
        if (preHeld) ADAPTER.acquire();
        address before = LOCK.holder();
        try OUTSIDER.acquire() {
            assert(false);
        } catch (bytes memory reason) {
            assert(keccak256(reason) == keccak256(abi.encodeWithSelector(ILock.NotMember.selector, address(OUTSIDER))));
        }
        assert(LOCK.holder() == before);
        if (preHeld) ADAPTER.release();
        ++sequences;
    }

    /// @notice An outer call that returns without releasing: later calls in the same transaction fail closed, and the
    /// property `property_freeAtTransactionStart` checks the lock is free again in the next transaction.
    function acquireWithoutRelease(
        bool swapHolds
    ) external {
        LockMember holder = swapHolds ? SWAP : ADAPTER;
        LockMember other = swapHolds ? ADAPTER : SWAP;
        holder.acquire();
        try other.acquire() {
            assert(false);
        } catch {}
        assert(LOCK.holder() == address(holder));
        ++sequences;
    }

    /// @notice An outer call that reverts after acquiring leaves the lock free.
    function revertedOuterCall(
        bool swapHolds
    ) external {
        LockMember holder = swapHolds ? SWAP : ADAPTER;
        try holder.acquireAndRevert() {
            assert(false);
        } catch {}
        assert(LOCK.holder() == address(0));
        holder.acquire();
        holder.release();
        ++sequences;
    }
}
