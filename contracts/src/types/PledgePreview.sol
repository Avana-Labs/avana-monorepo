// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Non-reverting outcome of the pledge checks for the app and the Lens.
/// @dev Room values are 8-decimal USD, except `poolShareRoomUnits` in vault-token base units.
struct PledgePreview {
    // True when checkPledge would pass.
    bool eligible;
    // Selector of the first failing custom error, or 0.
    bytes4 reason;
    // True when the account has debt on any debt reserve of the market's CDP Spoke.
    bool isTopUp;
    // Charge that would be booked.
    uint256 usdCharge;
    // Slice part of the charge.
    uint256 sliceUsd;
    // marketUsdCap minus the regular counter, floored at 0.
    uint256 marketRoomUsd;
    // topUpSliceUsd minus the slice counter, floored at 0.
    uint256 sliceRoomUsd;
    // Per-token room in pool order.
    uint256[] tokenRoomUsd;
    // Units still admissible under the pool-share cap.
    uint256 poolShareRoomUnits;
    // Open records the account may still add to the market.
    uint256 recordRoom;
}
