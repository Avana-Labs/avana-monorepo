// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One speed window: the current bucket `[start, start + window)` and the bucket before it.
/// @dev One storage slot. Amounts are 8-decimal USD for market and pledge windows and asset base units for (Hub, asset)
/// windows; `prev + curr` never exceeds the scope's `max`, which fits `uint96`.
/// @custom:spec SPEC-CAP-011, REQ-RISK-095, Q-411
struct SpeedWindow {
    // Start of the current bucket, seconds.
    uint64 start;
    // Charges of the bucket before the current one.
    uint96 prev;
    // Charges of the current bucket.
    uint96 curr;
}
