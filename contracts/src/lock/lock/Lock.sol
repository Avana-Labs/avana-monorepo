// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILock} from "./ILock.sol";
import {LockSlot} from "./LockSlot.sol";

/// @title Lock
/// @notice The chain's single reentrancy lock, taken by the AaveAdapter or LPVaultSwap at each outer entry point.
/// @dev Immutable, no owner and no events. The holder is kept in transient storage at `LockSlot.HOLDER_SLOT`.
contract Lock is ILock {
    address private immutable _AAVE_ADAPTER;

    address private immutable _LP_VAULT_SWAP;

    address private immutable _SELF;

    /// @notice Fixes the two members at their predicted proxy addresses; neither needs code at deployment.
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

    modifier noDelegateCall() {
        if (address(this) != _SELF) revert DelegateCallNotAllowed();
        _;
    }

    /// @inheritdoc ILock
    function acquire() external override noDelegateCall {
        if (msg.sender != _AAVE_ADAPTER && msg.sender != _LP_VAULT_SWAP) revert NotMember(msg.sender);
        address current = _holder();
        if (current != address(0)) revert LockHeld(current);
        _setHolder(msg.sender);
    }

    /// @inheritdoc ILock
    function release() external override noDelegateCall {
        address current = _holder();
        if (current == address(0) || msg.sender != current) revert NotHolder(msg.sender);
        _setHolder(address(0));
    }

    /// @inheritdoc ILock
    function holder() external view override noDelegateCall returns (address currentHolder) {
        currentHolder = _holder();
    }

    /// @inheritdoc ILock
    function isLocked() external view override noDelegateCall returns (bool locked) {
        locked = _holder() != address(0);
    }

    /// @inheritdoc ILock
    function AAVE_ADAPTER() external view override noDelegateCall returns (address aaveAdapter) {
        aaveAdapter = _AAVE_ADAPTER;
    }

    /// @inheritdoc ILock
    function LP_VAULT_SWAP() external view override noDelegateCall returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc ILock
    function SELF() external view override noDelegateCall returns (address self) {
        self = _SELF;
    }

    function _holder() private view returns (address current) {
        bytes32 slot = LockSlot.HOLDER_SLOT;
        // Solidity has no transient read at a chosen slot.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            current := tload(slot)
        }
    }

    function _setHolder(
        address next
    ) private {
        bytes32 slot = LockSlot.HOLDER_SLOT;
        // Solidity has no transient write at a chosen slot.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            tstore(slot, next)
        }
    }
}
