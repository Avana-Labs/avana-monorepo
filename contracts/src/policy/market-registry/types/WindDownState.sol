// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Offboarding record of one market: notice start, the liquidation threshold then, and its target.
/// @dev Field layout is fixed for storage compatibility; `unusedLastStepAt` is always 0.
struct WindDownState {
    // `setMarketOffboarding` time, seconds; 0 while not offboarding.
    uint64 offboardedAt;
    // Unused; always 0.
    uint64 unusedLastStepAt;
    // Collateral factor of the reserve's latest dynamic key when offboarding began, bps.
    uint16 startLtBps;
    // Liquidation threshold the Aave DAO sets after the notice, bps (half of `startLtBps`, rounded down).
    uint16 targetLtBps;
}
