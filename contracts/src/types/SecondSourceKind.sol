// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Kind of a token's independent second price source.
/// @dev Ordinal values are fixed.
enum SecondSourceKind {
    None,
    OracleNetwork,
    PoolTwap
}
