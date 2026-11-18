// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice L2 sequencer-uptime check of a chain.
/// @dev `feed == address(0)` on a chain without a sequencer.
struct SequencerConfig {
    // Chainlink sequencer-uptime feed, or address(0).
    address feed;
    // Grace period after a restart, seconds.
    uint32 gracePeriod;
}
