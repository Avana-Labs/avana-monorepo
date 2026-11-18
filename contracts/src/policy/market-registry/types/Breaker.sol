// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Circuit-breaker reason bits: live conditions read from current state on every check, with no latch and no
/// recovery delay. A breaker holds exactly while one of its conditions holds. Unused bits are never set.
library BreakerReasons {
    /// @notice Market or debt: the issuer probe reports a pause or a transfer fee switched on.
    uint32 internal constant ISSUER = 1 << 3;
    /// @notice Debt: the funding Hub's deficit on the Spoke is above `deficitMax`.
    uint32 internal constant DEFICIT = 1 << 5;
    /// @notice Market: the Aave configuration drift check reports drift on the market's Spoke.
    uint32 internal constant CONFIG_DRIFT = 1 << 10;
    /// @notice Market: the pool's time-weighted depth is unavailable or zero.
    uint32 internal constant POOL_DEPTH = 1 << 11;
    /// @notice Every reason a market breaker can report.
    uint32 internal constant MARKET = ISSUER | CONFIG_DRIFT | POOL_DEPTH;
    /// @notice Every reason a debt breaker can report.
    uint32 internal constant DEBT = ISSUER | DEFICIT;
}
