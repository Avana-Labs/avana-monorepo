// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISequencerUptimeFeed
/// @notice Chainlink L2 sequencer-uptime feed, read through `AggregatorV3Interface.latestRoundData`.
/// @dev `answer == 0` means up, `1` down; `startedAt == 0` (round not initialised) counts as down.
interface ISequencerUptimeFeed {
    /// @notice Returns the latest status round: `answer` 0 up, 1 down; `startedAt` start of the current status.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
