// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAggregatorV3
/// @notice Subset of Chainlink's `AggregatorV3Interface` that Avana contracts call on a feed proxy, copied from
/// `contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol` of smartcontractkit/chainlink-evm at commit
/// 4d83db28afc6d54761ce324e633d89244a97907e, with identical selectors.
/// @dev Called by: LPOracle, RiskModule, ParameterStore.
interface IAggregatorV3 {
    /// @notice Returns the number of decimals of the answer. Source:
    /// `contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol` (chainlink-evm 4d83db2).
    /// @dev Called by: LPOracle, ParameterStore.
    function decimals() external view returns (uint8);

    /// @notice Returns the data of round `_roundId`. Source:
    /// `contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol` (chainlink-evm 4d83db2).
    /// @dev Called by: LPOracle.
    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Returns the data of the latest round. Source:
    /// `contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol` (chainlink-evm 4d83db2).
    /// @dev Called by: LPOracle, RiskModule, ParameterStore.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
