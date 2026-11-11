// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Avana's application pause state, held by the MarketRegistry and read by the AaveAdapter and the Lens.
/// @dev `None` allows everything. `Frozen` blocks new pledges by accounts with no debt and borrowing. `Paused` also
/// blocks non-rescue top-ups and re-credits, withdraw-with-debt, removal with debt and repay with collateral; with
/// `PauseReason.MintPathSuspect` it blocks rescue top-ups too. Repay, fee collection, debt-free withdrawal and removal,
/// zero-credit release, liquidation and pending settlement never depend on it; LPVaultSwap never reads it. Ordinal
/// values are fixed: `None` 0, `Frozen` 1, `Paused` 2.
/// @custom:spec REQ-MREG-001, REQ-MREG-002, REQ-MREG-024, Q-227, Q-252
enum PauseState {
    None,
    Frozen,
    Paused
}
