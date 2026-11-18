// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Avana's application pause state, held by the MarketRegistry and read by the AaveAdapter and the Lens.
/// @dev Repay, liquidation and debt-free withdrawal never depend on it. Ordinal values are fixed.
enum PauseState {
    None,
    Frozen,
    Paused
}
