// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Scope of a circuit breaker: one market, or one (CDP Spoke, debt reserve).
/// @dev A market key is `bytes32(marketId)`; a debt key is `keccak256(abi.encode(spoke, debtReserveId))`.
/// @custom:spec REQ-MREG-025, Q-241
enum BreakerScope {
    Market,
    DebtReserve
}

/// @notice Circuit-breaker reason bits (Q-399). Temporary gates (`ORACLE`, `POOL_SHARE`, `POOL_DEPTH`) block while
/// their condition holds and reopen `gateRecoverySeconds` after their last recorded breach. Security freezes (`ISSUER`,
/// `CONFIG_DRIFT`, `DEFICIT`, `MANUAL`) block while their condition holds and, once latched by `pokeBreakers` or a
/// manual trip, until an authorized reset. Bits 1, 4, 6, 7 and 8 (former price-drop, coverage, budget, seizure-surge
/// and route-failure reasons) are retired and never set: those signals are monitoring alerts, and the settlement budget
/// is removed (Q-397).
/// @custom:spec REQ-MREG-025, SPEC-BRK-005, SPEC-BRK-006, SPEC-BRK-007, SPEC-BRK-008, Q-241, Q-399
library BreakerReasons {
    /// @notice Temporary gate: the price-state or debt-price gate fails, or a stablecoin-band breach.
    uint32 internal constant ORACLE = 1 << 0;
    /// @notice Temporary gate, market: Avana's units above `poolShareMaxBpsOf(poolKey)` of the pool's depth, summed over every
    /// market of the pool on the chain, across every borrower, Hub and Spoke (SPEC-BRK-002).
    uint32 internal constant POOL_SHARE = 1 << 2;
    /// @notice Security freeze, market (pool tokens) or debt (asset): the listing's issuer probe reports an issuer
    /// action (a pause, or a transfer fee switched on). For a debt asset with a fee, new borrows of every reserve of
    /// that asset stop, while liquidation and repay continue with every amount measured by balance delta (AMMN N2b,
    /// REQ-SWAP-123).
    uint32 internal constant ISSUER = 1 << 3;
    /// @notice Security freeze, debt: the funding Hub's deficit on the Spoke above `breakerDeficitMax` (10,000 GHO
    /// for a GHO reserve; a per-reserve materiality set at listing for other assets).
    uint32 internal constant DEFICIT = 1 << 5;
    /// @notice Security freeze: a guardian or admin trip.
    uint32 internal constant MANUAL = 1 << 9;
    /// @notice Security freeze, Spoke: the Aave configuration drift check reports drift (REQ-RISK-078, REQ-RISK-088,
    /// Q-350, Q-352). Every gated call evaluates it; `pokeConfig` and `pokeBreakers` latch it.
    uint32 internal constant CONFIG_DRIFT = 1 << 10;
    /// @notice Temporary gate, market: the pool's time-weighted depth is unavailable or below the listing minimum
    /// (REQ-RISK-088, SPEC-CAP-005).
    uint32 internal constant POOL_DEPTH = 1 << 11;
    /// @notice The temporary-gate reasons.
    uint32 internal constant TEMPORARY = ORACLE | POOL_SHARE | POOL_DEPTH;
    /// @notice The security-freeze reasons a poke can latch.
    uint32 internal constant SECURITY = ISSUER | CONFIG_DRIFT | DEFICIT;
}
