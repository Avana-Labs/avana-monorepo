// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title LockSlot
/// @notice Transient storage slot of the lock holder.
/// @dev `HOLDER_SLOT = keccak256(abi.encode(uint256(keccak256("avana.lock.holder")) - 1)) & ~bytes32(uint256(0xff))`.
/// @custom:spec REQ-LOCK-002
library LockSlot {
    /// @notice ERC-7201 slot `avana.lock.holder`, written with `TSTORE` and read with `TLOAD`.
    bytes32 internal constant HOLDER_SLOT = 0x9766526454735bfdc974cd00b16c7cbec0f906b403c1cb2840e1033ac5574400;
}
