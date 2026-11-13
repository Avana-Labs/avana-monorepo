// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One speed window as the next check would see it now.
/// @dev `used = prev + curr` after the rollover; `available = limit − used`, floored at 0; `moreAt` is when the next
/// charges stop counting (0 when the window is empty) and `moreAmount` how much stops then. With `unavailable` set a
/// read failed and every other field is 0.
/// @custom:spec REQ-RISK-097, SPEC-CAP-011, Q-411
struct SpeedView {
    // Limit L of SPEC-CAP-012 now.
    uint256 limit;
    // Charges still counting.
    uint256 used;
    // Room for the next charge.
    uint256 available;
    // Time the next charges stop counting, or 0.
    uint64 moreAt;
    // Charges that stop counting at moreAt.
    uint256 moreAmount;
    // True when a read failed.
    bool unavailable;
}
