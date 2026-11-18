// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAggregatorV3
/// @notice Subset of Chainlink's `AggregatorV3Interface` that Avana calls on a feed proxy.
/// @dev Copied from chainlink-evm `AggregatorV3Interface.sol` (4d83db2), identical selectors.
interface IAggregatorV3 {
    /// @notice Returns the number of decimals of the answer.
    function decimals() external view returns (uint8);

    /// @notice Returns the data of round `_roundId`.
    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Returns the data of the latest round.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
