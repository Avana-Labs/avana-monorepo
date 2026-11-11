// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreChain
/// @notice Parameters that differ by chain: the block time, the L2 sequencer-uptime check and each feed's heartbeat
/// margin. Avana has no minimum debt on any chain (`Q-381`): a borrower may borrow any amount, and Avana's own keepers
/// liquidate every account and pay its gas, so no liquidation depends on a keeper's profit.
/// @dev Every setter requires `APPLICATION_ADMIN` (the chain's timelock, normal delay unless noted). Launch values:
///
/// | Parameter | Ethereum | Base |
/// |---|---|---|
/// | `CHAIN_BLOCK_TIME` (implementation immutable) | 12 s | 2 s |
/// | `sequencer().feed` | `address(0)` (no sequencer) | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` |
/// | `sequencer().gracePeriod` | 0 | 3,600 s |
///
/// `SPEC-CHAIN-001` is the per-chain gas model of one liquidation, in gas units: `G(n) = 1,310,000 + 240,000 × n` for
/// an account with `n` records, flash loan included. It sizes the record cap: the largest account, `n =
/// AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET = 16`, needs `G(16) = 5,150,000` gas, within half the per-transaction
/// gas limit (`16,777,216 / 2 = 8,388,608`), so one transaction always liquidates it with half the limit to spare. It also sets Avana's keeper gas budget; the gas price
/// is an operating input, not a parameter here.
/// @custom:spec SPEC-CHAIN-001, REQ-PSTORE-023, REQ-PSTORE-027, Q-324, Q-381
interface IParameterStoreChain {
    /// @notice The sequencer-uptime check changed.
    /// @param feed New feed, `address(0)` on a chain with no sequencer.
    /// @param gracePeriod New grace period, seconds.
    /// @custom:spec REQ-PSTORE-023
    event SequencerSet(address feed, uint32 gracePeriod);

    /// @notice The sequencer feed failed its check: on an L2 it holds no code or its `latestRoundData()` does not
    /// return an answer of 0 (up) or 1 (down) with `startedAt > 0`; on Ethereum it is not `address(0)`.
    /// @param feed The rejected feed.
    /// @custom:spec REQ-PSTORE-023
    error InvalidSequencerFeed(address feed);

    /// @notice Sets the sequencer-uptime feed and the grace period after a restart.
    /// @dev Normal delay. On an L2, reverts `InvalidSequencerFeed(feed)` unless the feed passes its check and
    /// `OutOfBounds` unless `600 <= gracePeriod <= 7,200`; on Ethereum, reverts `InvalidSequencerFeed(feed)` unless
    /// `feed == address(0)` and `OutOfBounds` unless `gracePeriod == 0`. While the feed reports down, borrow and
    /// withdraw-with-debt are refused and the market's seizure is paused; during the grace period borrowing is refused
    /// and LPVaultSwap liquidates only below `graceHealthFactor`; an unreadable feed blocks borrowing only
    /// (`SPEC-ORC-021`). Emits `SequencerSet`.
    /// @param feed Chainlink sequencer-uptime feed, or `address(0)` on a chain with no sequencer.
    /// @param gracePeriod Seconds after restart.
    /// @custom:spec REQ-PSTORE-023, REQ-ORACLE-099, SPEC-ORC-021, Q-324
    function setSequencer(
        address feed,
        uint32 gracePeriod
    ) external;

    /// @notice The chain's sequencer-uptime feed and grace period.
    /// @return feed The feed, `address(0)` when the chain has none.
    /// @return gracePeriod Seconds.
    /// @custom:spec REQ-PSTORE-023
    function sequencer() external view returns (address feed, uint32 gracePeriod);

    /// @notice Seconds per block on this chain, an implementation immutable (12 on Ethereum, 2 on Base).
    /// @dev Sizes `twapMinObservations(marketId) = ceil(twapWindow / CHAIN_BLOCK_TIME) + 1`: 151 on Ethereum and 901 on
    /// Base for a 1,800 s window (`SPEC-ORC-022`).
    /// @return value Seconds.
    /// @custom:spec REQ-PSTORE-027, SPEC-ORC-022, Q-326
    function CHAIN_BLOCK_TIME() external view returns (uint32 value);

    /// @notice Minimum observation-buffer length a market's pool must hold for its consistency window.
    /// @dev `ceil(twapWindow / CHAIN_BLOCK_TIME) + 1`, or 0 when the market has no time-weighted price
    /// (`twapWindow == 0`).
    /// @param marketId The market.
    /// @return count Observation slots.
    /// @custom:spec REQ-PSTORE-027, SPEC-ORC-022, Q-326
    function twapMinObservations(
        uint256 marketId
    ) external view returns (uint16 count);

    /// @notice Heartbeat margin of a feed, written by `setFeed` with the rest of its `FeedDef`.
    /// @dev A feed is fresh while its age is at most its own heartbeat plus this margin: Chainlink stablecoin feeds have
    /// heartbeats of 82,800 to 86,400 s, so one fixed age bound for every feed would either reject them most of the day
    /// or accept stale volatile feeds (AMMN-INT-01). Launch 1,800 s per feed; at most `MAX_HEARTBEAT_MARGIN` (3,600 s).
    /// @param feed Chainlink aggregator proxy.
    /// @return margin Seconds.
    /// @custom:spec REQ-CONFIG-023, SPEC-ORC-019, Q-322
    function heartbeatMargin(
        address feed
    ) external view returns (uint32 margin);
}
