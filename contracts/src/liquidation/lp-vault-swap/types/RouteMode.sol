// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Swap-route mode chosen by the caller of `liquidate`.
/// @dev `PrimaryThenBackup` tries the usable primary swap route of each pool token inside try/catch and falls back to
/// the usable backup; `BackupOnly` uses only the backups. Every caller may choose either mode (Q-404). There is no
/// in-kind mode (Q-401).
/// @custom:spec REQ-SWAP-010, REQ-SWAP-022, REQ-SWAP-030, REQ-SWAP-046, REQ-SWAP-072
enum RouteMode {
    PrimaryThenBackup,
    BackupOnly
}
