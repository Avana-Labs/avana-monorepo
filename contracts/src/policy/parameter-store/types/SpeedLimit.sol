// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Borrow-speed limit of one (funding Hub, debt asset), in base units of new draws per window.
struct SpeedLimit {
    // Share of the base allowed per window, bps.
    uint16 rateBps;
    // Window length, seconds.
    uint32 window;
    // Smallest limit, asset base units.
    uint96 min;
    // Largest limit, asset base units.
    uint96 max;
}
