// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Kind of position shape a market accepts.
/// @dev Ordinal values are fixed.
enum ShapeKind {
    None,
    TickRange,
    FullPool
}
