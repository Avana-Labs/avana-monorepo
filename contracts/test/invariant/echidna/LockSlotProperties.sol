// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LockSlot} from "../../../src/lock/lock/LockSlot.sol";

/// @title LockSlotProperties
/// @notice Echidna and Medusa properties of `LockSlot.HOLDER_SLOT`, the transient slot of the lock holder. The slot is
/// the ERC-7201 location of the namespace `avana.lock.holder`, its low byte is zero, a holder written with `TSTORE` is
/// read back unchanged with `TLOAD` in the same transaction, and the slot is empty again at the start of every later
/// transaction, so a lock can never outlive the transaction that took it.
/// @dev `property_` functions run in property mode, each as its own call after every fuzzed transaction; `enter` and
/// `enterAndRelease` run in assertion mode.
contract LockSlotProperties {
    /// @notice Number of holders written in assertion mode; written so the call is a transaction.
    uint256 public entries;

    function property_holderSlotIsErc7201() external pure returns (bool) {
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("avana.lock.holder")) - 1)) & ~bytes32(uint256(0xff));
        return LockSlot.HOLDER_SLOT == expected;
    }

    function property_holderSlotLowByteIsZero() external pure returns (bool) {
        return uint256(LockSlot.HOLDER_SLOT) & 0xff == 0;
    }

    function property_holderSlotEmptyAtTransactionStart() external view returns (bool) {
        return _holder() == address(0);
    }

    /// @notice A holder written to the slot reads back unchanged within the transaction.
    function enter(
        address holder
    ) external {
        _setHolder(holder);
        assert(_holder() == holder);
        ++entries;
    }

    /// @notice Writing a holder and then clearing it leaves the slot empty within the transaction.
    function enterAndRelease(
        address holder
    ) external {
        _setHolder(holder);
        _setHolder(address(0));
        assert(_holder() == address(0));
        ++entries;
    }

    function _setHolder(
        address holder
    ) internal {
        bytes32 slot = LockSlot.HOLDER_SLOT;
        assembly ("memory-safe") {
            tstore(slot, holder)
        }
    }

    function _holder() internal view returns (address holder) {
        bytes32 slot = LockSlot.HOLDER_SLOT;
        assembly ("memory-safe") {
            holder := tload(slot)
        }
    }
}
