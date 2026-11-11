// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Kind of a token's independent second price source.
/// @dev `OracleNetwork`: an aggregator of a second oracle network with an `AggregatorV3` interface. `PoolTwap`: the
/// time-weighted price of a deep pool, read through an AMM integration's `twapPrice`. Ordinal values are fixed.
/// @custom:spec REQ-ORACLE-100, SPEC-ORC-020, Q-323
enum SecondSourceKind {
    None,
    OracleNetwork,
    PoolTwap
}
