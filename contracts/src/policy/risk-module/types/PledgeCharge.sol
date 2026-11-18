// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice USD exposure a pledge books against the caps.
/// @dev `usdCharge` is rounded up; `sliceUsd <= usdCharge`.
struct PledgeCharge {
    // Stress-floor booked USD value of the pledge, 8 decimals.
    uint256 usdCharge;
    // Part of usdCharge booked against the top-up slice, 8 decimals.
    uint256 sliceUsd;
    bool rescue;
    // Units added to the record's rescue units, at most the pledged liquidity.
    uint128 rescueUnits;
}
