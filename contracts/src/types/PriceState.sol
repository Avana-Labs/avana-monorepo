// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Price state of one market's LPOracle feed or one debt asset's DebtOracle, ordered by severity.
/// @dev `Live` (0) < `Drifting` (1) < `Cached` (2) < `Expired` (3). Each oracle computes the state on every read from
/// current feed (and, for the LPOracle, pool) data plus its stored timers, with no hysteresis. A DebtOracle is Drifting
/// only while its two routes disagree. LPOracle, DebtOracle, RiskModule, Collateralization, LPVaultSwap and the Lens read
/// this type.
/// @custom:spec REQ-ORACLE-016, REQ-ORACLE-092, Q-128, Q-248
enum PriceState {
    Live,
    Drifting,
    Cached,
    Expired
}
