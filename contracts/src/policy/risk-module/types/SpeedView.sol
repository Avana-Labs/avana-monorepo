// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One speed window as the next check would see it now.
/// @dev With `unavailable` set a read failed and every other field is 0.
struct SpeedView {
    uint256 limit;
    // Charges still counting.
    uint256 used;
    // Room for the next charge: limit less used, floored at 0.
    uint256 available;
    // Time the next charges stop counting, or 0.
    uint64 moreAt;
    // Charges that stop counting at moreAt.
    uint256 moreAmount;
    bool unavailable;
}
