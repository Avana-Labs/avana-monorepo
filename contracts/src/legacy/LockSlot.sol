// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title LockSlot
/// @notice Transient storage slot of the lock holder.
library LockSlot {
    /// @notice ERC-7201 slot `avana.lock.holder`.
    bytes32 internal constant HOLDER_SLOT = 0x9766526454735bfdc974cd00b16c7cbec0f906b403c1cb2840e1033ac5574400;
}
