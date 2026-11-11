// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Non-reverting outcome of the pledge checks for the app and the Lens.
/// @dev `reason` is the selector of the custom error `checkPledge` would revert with (0 when eligible), including
/// `BelowMinPledge.selector` and `TooManyRecords.selector`. Remaining room values are 8-decimal USD, except
/// `poolShareRoomUnits` in vault-token base units. `tokenRoomUsd[i]` is `tokenUsdCap(hub, tokens[i])` minus its
/// counter, floored at 0, in pool order.
/// @custom:spec REQ-RISK-031, REQ-RISK-057, Q-370
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
    // depositorUsdCap minus the depositor counter, floored at 0.
    uint256 depositorRoomUsd;
    // Units still admissible under the pool-share cap.
    uint256 poolShareRoomUnits;
    // Open records the account may still add to the market (MAX_RECORDS_PER_ACCOUNT_MARKET minus open records).
    uint256 recordRoom;
}
