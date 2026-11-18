// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Why the application is Paused, held by the MarketRegistry beside `PauseState`.
/// @dev `None` exactly when the state is not Paused; ordinal values are fixed.
enum PauseReason {
    None,
    General,
    MintPathSuspect
}
