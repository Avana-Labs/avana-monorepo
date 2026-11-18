// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice How an AMM protocol identifies a pool.
/// @dev `Address`: a pool contract address. `Id`: a `bytes32` identifier inside a singleton. Ordinal values are fixed.
enum PoolKeying {
    Address,
    Id
}
