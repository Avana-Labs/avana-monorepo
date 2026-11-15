// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One net-flow speed window: the current bucket `[start, start + window)`, the bucket before it, and the
/// scope's window-start base.
/// @dev Two storage slots. Amounts are 8-decimal USD for market and pledge windows and asset base units for (Hub, asset)
/// windows; `prev + curr` never exceeds the scope's `max`, which fits `uint96`. `prev` and `curr` are net: a charge adds
/// to `curr`, a credit (a repay or a withdrawal) takes from `curr` and then `prev`, and neither goes below zero. `base`
/// is written when a charge opens the current bucket (`start` set to the bucket's start): the scope's base at that
/// moment less `prev`, the base when the window began.
/// @custom:spec SPEC-CAP-011, SPEC-CAP-012, REQ-RISK-095, Q-411
struct SpeedWindow {
    // Start of the current bucket, seconds; 0 for a window never written.
    uint64 start;
    // Net charges of the bucket before the current one.
    uint96 prev;
    // Net charges of the current bucket.
    uint96 curr;
    // The window-start base the limit is computed on, written with the current bucket's first charge.
    uint256 base;
}
