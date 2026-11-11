// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice L2 sequencer-uptime check of a chain.
/// @dev `feed == address(0)` on a chain without a sequencer (Ethereum). Otherwise every LPOracle and DebtOracle
/// evaluation reads the feed (`SPEC-ORC-021`). While the feed reports down (`answer == 1`), `borrowAllowed` is false
/// and `liquidationPaused` is true (reason `SEQUENCER_DOWN`). During the grace period after a restart
/// (`now - startedAt < gracePeriod`), `borrowAllowed` is false and `inGrace` is true (reason `SEQUENCER_GRACE`), so
/// LPVaultSwap liquidates only below `graceHealthFactor`, because positions could not be topped up while the
/// sequencer was down. An unreadable feed blocks borrowing only and never pauses liquidation. Base: feed
/// `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`, grace period 3,600 s: a restart at t = 1,000,000 blocks borrowing
/// until t = 1,003,600.
/// @custom:spec REQ-CHAIN-001, REQ-ORACLE-099, SPEC-ORC-021, Q-324
struct SequencerConfig {
    // Chainlink sequencer-uptime feed, or address(0).
    address feed;
    // Grace period after a restart, seconds.
    uint32 gracePeriod;
}
