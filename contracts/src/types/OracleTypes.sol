// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Price state of one market's LPOracle feed or one debt asset's DebtOracle, ordered by severity.
enum PriceState {
    Live,
    Drifting,
    Cached,
    Expired
}

