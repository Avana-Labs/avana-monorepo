// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SecondSourceKind} from "./SecondSourceKind.sol";

/// @notice Independent second price source of one token, required to agree before a borrow or a withdrawal.
/// @dev Passes when `|q - s| * 1e4 <= toleranceBps * min(q, s)`; liquidation never reads it.
struct SecondSource {
    SecondSourceKind kind;
    // Aggregator (OracleNetwork) or AMM integration (PoolTwap).
    address source;
    // Pool address or identifier for PoolTwap (bytes32(uint160(pool)) for an address-keyed pool).
    bytes32 poolRef;
    // Maximum accepted age of an OracleNetwork answer, seconds.
    uint32 maxAge;
    // TWAP window of a PoolTwap, seconds.
    uint32 twapWindow;
    // Agreement tolerance with the served quote, bps.
    uint16 toleranceBps;
}
