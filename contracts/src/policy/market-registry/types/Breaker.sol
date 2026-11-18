// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Scope of a circuit breaker: one market, or one (CDP Spoke, debt reserve).
/// @dev A market key is `bytes32(marketId)`; a debt key is `keccak256(abi.encode(spoke, debtReserveId))`.
enum BreakerScope {
    Market,
    DebtReserve
}

/// @notice Circuit-breaker reason bits. Temporary gates reopen `gateRecoverySeconds` after their last breach;
/// security freezes, once latched, hold until an authorized reset. Unused bits are never set.
library BreakerReasons {
    /// @notice Temporary gate: the price-state or debt-price gate fails, or a stablecoin-band breach.
    uint32 internal constant ORACLE = 1 << 0;
    /// @notice Security freeze, market or debt: the issuer probe reports a pause or a transfer fee switched on.
    uint32 internal constant ISSUER = 1 << 3;
    /// @notice Security freeze, debt: the funding Hub's deficit on the Spoke is above `breakerDeficitMax`.
    uint32 internal constant DEFICIT = 1 << 5;
    /// @notice Security freeze: a guardian or admin trip.
    uint32 internal constant MANUAL = 1 << 9;
    /// @notice Security freeze, Spoke: the Aave configuration drift check reports drift.
    uint32 internal constant CONFIG_DRIFT = 1 << 10;
    /// @notice Temporary gate, market: the pool's time-weighted depth is unavailable or below the listing minimum.
    uint32 internal constant POOL_DEPTH = 1 << 11;
    /// @notice The temporary-gate reasons.
    uint32 internal constant TEMPORARY = ORACLE | POOL_DEPTH;
    /// @notice The security-freeze reasons a poke can latch.
    uint32 internal constant SECURITY = ISSUER | CONFIG_DRIFT | DEFICIT;

    /// @notice The key under which the MarketRegistry keeps the breach time of one temporary reason of breaker `key`.
    /// @param reason One temporary reason bit (`ORACLE` or `POOL_DEPTH`).
    function breachKey(
        bytes32 key,
        uint32 reason
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, reason));
    }
}
