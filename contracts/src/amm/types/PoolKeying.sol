// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice How an AMM protocol identifies a pool.
/// @dev `Address`: a pool contract address (Uniswap v3, Slipstream, Uniswap v2, Curve). `Id`: a `bytes32` identifier
/// inside a singleton (Uniswap v4 `PoolId`, Balancer pool id). Ordinal values are fixed.
/// @custom:spec REQ-AMM-CORE-010, Q-371
enum PoolKeying {
    Address,
    Id
}
