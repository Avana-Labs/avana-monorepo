// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Offboarding record of one market (REQ-MREG-015, REQ-CONFIG-080).
/// @custom:spec REQ-MREG-015, REQ-CONFIG-080
struct WindDownState {
    // `setMarketOffboarding` time, seconds; 0 while not offboarding.
    uint64 offboardedAt;
    // Time of the last `stepWindDown`, seconds; 0 before the first step.
    uint64 lastStepAt;
    // Collateral factor of the reserve's latest dynamic key when offboarding began, bps (the ramp's start).
    uint16 startLtBps;
    // Liquidation threshold of the last step, bps (`startLtBps` before the first step).
    uint16 currentLtBps;
}
