// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreChain
/// @notice Parameters that differ by chain: block time, sequencer-uptime check and feed heartbeat margins.
/// @dev Every setter requires `APPLICATION_ADMIN` (the timelock, normal delay).
interface IParameterStoreChain {
    /// @notice The sequencer-uptime check changed.
    /// @param feed New feed, `address(0)` on a chain with no sequencer.
    /// @param gracePeriod New grace period, seconds.
    event SequencerSet(address feed, uint32 gracePeriod);

    /// @notice The sequencer feed failed its check.
    error InvalidSequencerFeed(address feed);

    /// @notice Sets the sequencer-uptime feed and the grace period after a restart.
    /// @dev On a chain with no sequencer, `feed` must be `address(0)` and `gracePeriod` 0.
    /// @param gracePeriod Seconds after restart.
    function setSequencer(
        address feed,
        uint32 gracePeriod
    ) external;

    /// @notice The chain's sequencer-uptime feed and grace period.
    /// @return feed The feed, `address(0)` when the chain has none.
    /// @return gracePeriod Seconds.
    function sequencer() external view returns (address feed, uint32 gracePeriod);

    /// @notice Seconds per block on this chain, an implementation immutable.
    function CHAIN_BLOCK_TIME() external view returns (uint32 value);

    /// @notice Minimum observation-buffer length a market's pool must hold for its consistency window.
    /// @dev `ceil(twapWindow / CHAIN_BLOCK_TIME) + 1`, or 0 when `twapWindow == 0`.
    function twapMinObservations(
        uint256 marketId
    ) external view returns (uint16 count);

    /// @notice Heartbeat margin of a feed, written by `setFeed` with the rest of its `FeedDef`.
    /// @return margin Seconds.
    function heartbeatMargin(
        address feed
    ) external view returns (uint32 margin);
}
