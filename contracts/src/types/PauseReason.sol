// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Why the application is Paused, held by the MarketRegistry beside `PauseState`.
/// @dev `None` exactly when the state is not Paused. `General`: rescue top-ups are the only pledges. `MintPathSuspect`:
/// no pledge, top-up or re-credit runs, because every one mints vault tokens. Repay, debt-free withdrawal and removal,
/// fee collection, zero-credit release, pending settlement and liquidation never read it. Ordinal values are fixed:
/// `None` 0, `General` 1, `MintPathSuspect` 2.
/// @custom:spec REQ-MREG-024, Q-252
enum PauseReason {
    None,
    General,
    MintPathSuspect
}
