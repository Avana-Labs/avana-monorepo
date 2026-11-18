// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILock
/// @notice Chain-wide reentrancy lock shared by every Avana contract that moves assets or changes accounting.
/// @dev The holder lives in transient storage; only the AaveAdapter and LPVaultSwap can acquire it.
interface ILock {
    /// @notice The constructor was given a zero member or the same address for both members.
    error InvalidMembers();

    error DelegateCallNotAllowed();

    /// @notice `acquire()` was called by an address outside the fixed member set.
    error NotMember(address caller);

    /// @notice `acquire()` was called while the lock is held by any address, including the caller.
    error LockHeld(address holder);

    /// @notice `release()` was called by an address that is not the current holder.
    error NotHolder(address caller);

    /// @notice Takes the lock for `msg.sender`.
    /// @dev Only `AAVE_ADAPTER` or `LP_VAULT_SWAP`.
    function acquire() external;

    /// @notice Frees the lock.
    /// @dev Only the current holder can release.
    function release() external;

    /// @notice Returns the current holder.
    /// @return currentHolder The address in the holder slot, or `address(0)` when the lock is free.
    function holder() external view returns (address currentHolder);

    /// @notice Returns whether the lock is held.
    function isLocked() external view returns (bool locked);

    /// @notice Returns the AaveAdapter fixed proxy address, one of the two members.
    function AAVE_ADAPTER() external view returns (address aaveAdapter);

    /// @notice Returns the LPVaultSwap fixed proxy address, one of the two members.
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Returns the Lock's own deployed address, used for the delegatecall check.
    function SELF() external view returns (address self);
}
