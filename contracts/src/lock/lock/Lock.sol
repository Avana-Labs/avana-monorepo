// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILock} from "./ILock.sol";
import {LockSlot} from "./LockSlot.sol";

/// @title Lock
/// @notice The chain's single reentrancy lock: two fixed members, the AaveAdapter and LPVaultSwap, take it at the start
/// of every outer entry point and free it before every successful return; every inner Avana callee checks the holder.
/// @dev Immutable, with no owner, admin, setter, pause, upgrade path, fallback or `selfdestruct`; every function is
/// non-payable, so a call carrying ETH reverts before any check. The holder is one
/// address in EIP-1153 transient storage at `LockSlot.HOLDER_SLOT`, so the lock is free at the start of every
/// transaction and a revert rolls it back. No persistent storage, no external call, no event.
/// @custom:spec REQ-LOCK-001, REQ-LOCK-002, REQ-LOCK-012, REQ-LOCK-013, REQ-LOCK-014, REQ-LOCK-015, REQ-LOCK-018, REQ-LOCK-024, REQ-LOCK-027, INV-054, INV-091, Q-148, Q-318
contract Lock is ILock {
    /// @dev The chain's AaveAdapter proxy; read through `AAVE_ADAPTER()`, which also refuses delegatecall.
    address private immutable _AAVE_ADAPTER;

    /// @dev The chain's LPVaultSwap proxy; read through `LP_VAULT_SWAP()`.
    address private immutable _LP_VAULT_SWAP;

    /// @dev The Lock's own address, compared with `address(this)` by every function.
    address private immutable _SELF;

    /// @notice Fixes the two members at their predicted proxy addresses; neither needs code at deployment.
    /// @param aaveAdapter The chain's AaveAdapter proxy address (predicted).
    /// @param lpVaultSwap The chain's LPVaultSwap proxy address (predicted).
    /// @custom:spec REQ-LOCK-001, REQ-LOCK-029
    constructor(
        address aaveAdapter,
        address lpVaultSwap
    ) {
        if (aaveAdapter == address(0) || lpVaultSwap == address(0) || aaveAdapter == lpVaultSwap) {
            revert InvalidMembers();
        }
        _AAVE_ADAPTER = aaveAdapter;
        _LP_VAULT_SWAP = lpVaultSwap;
        _SELF = address(this);
    }

    /// @custom:spec REQ-LOCK-003, REQ-LOCK-022
    modifier noDelegateCall() {
        if (address(this) != _SELF) revert DelegateCallNotAllowed();
        _;
    }

    /// @inheritdoc ILock
    /// @custom:spec REQ-LOCK-004, REQ-LOCK-005, REQ-LOCK-006, REQ-LOCK-018, REQ-LOCK-019, REQ-LOCK-020, REQ-LOCK-025
    function acquire() external override noDelegateCall {
        if (msg.sender != _AAVE_ADAPTER && msg.sender != _LP_VAULT_SWAP) revert NotMember(msg.sender);
        address current = _holder();
        if (current != address(0)) revert LockHeld(current);
        _setHolder(msg.sender);
    }

    /// @inheritdoc ILock
    /// @custom:spec REQ-LOCK-008, REQ-LOCK-015, REQ-LOCK-018, REQ-LOCK-021
    function release() external override noDelegateCall {
        address current = _holder();
        // A free lock has no holder, so no caller (not even address(0)) can release it.
        if (current == address(0) || msg.sender != current) revert NotHolder(msg.sender);
        _setHolder(address(0));
    }

    /// @inheritdoc ILock
    /// @custom:spec REQ-LOCK-009
    function holder() external view override noDelegateCall returns (address currentHolder) {
        currentHolder = _holder();
    }

    /// @inheritdoc ILock
    /// @custom:spec REQ-LOCK-009, REQ-LOCK-016
    function isLocked() external view override noDelegateCall returns (bool locked) {
        locked = _holder() != address(0);
    }

    /// @inheritdoc ILock
    /// @custom:spec REQ-LOCK-001, REQ-LOCK-003, REQ-LOCK-004
    function AAVE_ADAPTER() external view override noDelegateCall returns (address aaveAdapter) {
        aaveAdapter = _AAVE_ADAPTER;
    }

    /// @inheritdoc ILock
    /// @custom:spec REQ-LOCK-001, REQ-LOCK-003, REQ-LOCK-004
    function LP_VAULT_SWAP() external view override noDelegateCall returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc ILock
    /// @custom:spec REQ-LOCK-001, REQ-LOCK-003
    function SELF() external view override noDelegateCall returns (address self) {
        self = _SELF;
    }

    /// @custom:spec REQ-LOCK-002
    function _holder() private view returns (address current) {
        bytes32 slot = LockSlot.HOLDER_SLOT;
        // EIP-1153 TLOAD of the fixed ERC-7201 slot (REQ-LOCK-002); Solidity has no transient read at a chosen slot.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            current := tload(slot)
        }
    }

    /// @custom:spec REQ-LOCK-002, REQ-LOCK-006, REQ-LOCK-008
    function _setHolder(
        address next
    ) private {
        bytes32 slot = LockSlot.HOLDER_SLOT;
        // EIP-1153 TSTORE of the fixed ERC-7201 slot (REQ-LOCK-002); Solidity has no transient write at a chosen slot.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            tstore(slot, next)
        }
    }
}
