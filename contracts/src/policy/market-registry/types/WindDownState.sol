// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Offboarding record of one market (REQ-MREG-015, REQ-CONFIG-080): when the notice began, the reserve's
/// liquidation threshold then, and the one target the Aave DAO lowers it to once the notice is over.
/// @dev The layout of the former ramp record is kept field for field, so no slot of the MarketRegistry's namespace
/// moves: the second field is unused and always 0, and the fourth holds the target.
/// @custom:spec REQ-MREG-015, REQ-CONFIG-080
struct WindDownState {
    // `setMarketOffboarding` time, seconds; 0 while not offboarding.
    uint64 offboardedAt;
    // Unused (the former ramp's last-step time); always 0.
    uint64 unusedLastStepAt;
    // Collateral factor of the reserve's latest dynamic key when offboarding began, bps.
    uint16 startLtBps;
    // Liquidation threshold the Aave DAO sets once, after the notice: ⌊startLtBps × 5,000 / 10,000⌋ bps.
    uint16 targetLtBps;
}
