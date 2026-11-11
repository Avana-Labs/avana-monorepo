// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice USD exposure a pledge books against the caps.
/// @dev `usdCharge` follows SPEC-CAP-001 (rounded up, at least 1 for L > 0); `sliceUsd <= usdCharge` is the part
/// booked against the market's top-up slice (SPEC-CAP-002). Collateralization adds `usdCharge - sliceUsd` to the regular
/// counter, `sliceUsd` to the slice counter, and the full `usdCharge` to every pool token counter and the depositor
/// counter. `rescue` marks a rescue top-up; `rescueUnits` (at most the pledged liquidity) is added to the record's
/// rescue units: all units of a rescue top-up, else the slice part `ceil(L * sliceUsd / usdCharge)`.
/// @custom:spec REQ-RISK-025, REQ-RISK-066, SPEC-CAP-001, SPEC-CAP-002, SPEC-BACK-014, Q-252, Q-253
struct PledgeCharge {
    // Stress-floor booked USD value of the pledge, 8 decimals.
    uint256 usdCharge;
    // Part of usdCharge booked against the top-up slice, 8 decimals.
    uint256 sliceUsd;
    // True when the pledge entered as a rescue top-up.
    bool rescue;
    // Units Collateralization books as the record's rescue units.
    uint128 rescueUnits;
}
