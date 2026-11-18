// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Swap-route mode chosen by the caller of `liquidate`.
enum RouteMode {
    PrimaryThenBackup,
    BackupOnly
}
