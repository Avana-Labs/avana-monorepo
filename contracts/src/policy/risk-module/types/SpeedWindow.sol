// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One net-flow speed window: the bucket `[start, start + window)`, the one before it, and its base.
/// @dev Two storage slots; `prev + curr` never exceeds the scope's `max`, which fits `uint96`.
struct SpeedWindow {
    // Start of the current bucket, seconds.
    uint64 start;
    // Net charges of the bucket before the current one.
    uint96 prev;
    // Net charges of the current bucket.
    uint96 curr;
    // The window-start base the limit is computed on, written with the bucket's first charge.
    uint248 base;
    // True once a charge opened the bucket starting at `start`, so `base` belongs to it.
    bool opened;
}
