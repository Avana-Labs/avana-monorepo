// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISequencerUptimeFeed
/// @notice Chainlink L2 sequencer-uptime feed, read through `AggregatorV3Interface.latestRoundData`, with identical
/// selectors.
/// @dev Called by: LPOracle, DebtOracle, RiskModule on an L2 chain. `answer == 0` means the sequencer is up and
/// `answer == 1` that it is down; `startedAt` is the time the current status began. A price is usable for borrow and
/// withdraw only when `answer == 0` and `block.timestamp - startedAt >= gracePeriod`; `startedAt == 0` (round not
/// initialised) counts as down. Base feed: `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`.
interface ISequencerUptimeFeed {
    /// @notice Returns the latest status round: `answer` 0 up, 1 down; `startedAt` start of the current status.
    /// @dev Called by: LPOracle, DebtOracle, RiskModule.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
