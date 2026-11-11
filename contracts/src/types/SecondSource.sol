// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SecondSourceKind} from "./SecondSourceKind.sol";

/// @notice Independent second price source of one token, required to agree before a borrow or a withdrawal.
/// @dev A borrow or withdrawal that relies on the token's price passes only when the served quote `q` and the second
/// source value `s` (both 8-decimal USD per whole token) satisfy `|q - s| * 1e4 <= toleranceBps * min(q, s)`,
/// computed in integers without rounding. Example with `toleranceBps = 100` and q = 100,020,000: s = 99,400,000 passes
/// (620,000 * 1e4 = 6.2e9 <= 100 * 99,400,000 = 9.94e9); s = 98,900,000 fails (1,120,000 * 1e4 = 1.12e10 >
/// 100 * 98,900,000 = 9.89e9), so that borrow reverts. A second source of another oracle network or a
/// deep pool cannot be moved by the same failure as the Chainlink routes; liquidation does not read it, so a broken
/// second source never blocks liquidation. `maxAge` applies to an `OracleNetwork` answer; `twapWindow` to a
/// `PoolTwap`.
/// @custom:spec REQ-ORACLE-100, SPEC-ORC-020, Q-323
struct SecondSource {
    // Source kind.
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
