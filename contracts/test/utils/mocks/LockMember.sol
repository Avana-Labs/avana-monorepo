// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILock} from "../../../src/lock/lock/ILock.sol";

/// @title LockMember
/// @notice Test stand-in for a Lock member (the AaveAdapter or LPVaultSwap) or for a non-member contract: it acquires,
/// releases, reverts while holding, or calls another contract while holding, so suites can drive every Lock state
/// inside one transaction. The Lock is set once after deployment, because the Lock's constructor needs the member's
/// address first, as in production where the members' addresses are predicted.
contract LockMember {
    error Boom();

    ILock public lock;

    function setLock(
        ILock lock_
    ) external {
        require(address(lock) == address(0), "lock set");
        lock = lock_;
    }

    function acquire() external {
        lock.acquire();
    }

    function release() external {
        lock.release();
    }

    /// @notice An outer call that reverts after acquiring; EIP-1153 rolls the holder back.
    function acquireAndRevert() external {
        lock.acquire();
        revert Boom();
    }

    /// @notice An outer call that acquires, makes one call while holding, and releases.
    function acquireCallRelease(
        address target,
        bytes calldata data
    ) external returns (bool ok, bytes memory ret) {
        lock.acquire();
        (ok, ret) = target.call(data);
        lock.release();
    }
}

/// @title LockDelegator
/// @notice Reaches every Lock function through `delegatecall`, which the Lock must refuse.
contract LockDelegator {
    function delegate(
        address lock,
        bytes calldata data
    ) external payable returns (bool ok, bytes memory ret) {
        (ok, ret) = lock.delegatecall(data);
    }

    /// @notice Reaches a Lock function through `staticcall`, as a view callee reads the holder.
    function staticProbe(
        address lock,
        bytes calldata data
    ) external view returns (bool ok, bytes memory ret) {
        (ok, ret) = lock.staticcall(data);
    }
}

/// @title LockHoldingReader
/// @notice A member that, while holding the lock, has a view contract read the holder through `staticcall`, the way
/// every inner callee checks the Lock.
contract LockHoldingReader {
    ILock public lock;

    function setLock(
        ILock lock_
    ) external {
        require(address(lock) == address(0), "lock set");
        lock = lock_;
    }

    function acquireAndProbe(
        LockDelegator probe
    ) external returns (address seenHolder, bool seenLocked) {
        lock.acquire();
        (, bytes memory h) = probe.staticProbe(address(lock), abi.encodeCall(ILock.holder, ()));
        (, bytes memory l) = probe.staticProbe(address(lock), abi.encodeCall(ILock.isLocked, ()));
        seenHolder = abi.decode(h, (address));
        seenLocked = abi.decode(l, (bool));
        lock.release();
    }
}
