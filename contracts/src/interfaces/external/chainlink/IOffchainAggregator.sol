// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IOffchainAggregator
/// @notice The answer bounds of a Chainlink OCR aggregator, declared as `int192 immutable public` in
/// `contract/OffchainAggregator.sol` and `contract2/OCR2Aggregator.sol` of smartcontractkit/libocr at commit
/// 199a6f17c59863999480e990c7c0b6ba7796ec92; these are the ABI-identical getters.
/// @dev Called by: ParameterStore (`setFeed`).
interface IOffchainAggregator {
    /// @notice Returns the lowest answer the aggregator accepts. Source: `contract/OffchainAggregator.sol`
    /// (libocr 199a6f1).
    /// @dev Called by: ParameterStore, in `setFeed`.
    function minAnswer() external view returns (int192);

    /// @notice Returns the highest answer the aggregator accepts. Source: `contract/OffchainAggregator.sol`
    /// (libocr 199a6f1).
    /// @dev Called by: ParameterStore, in `setFeed`.
    function maxAnswer() external view returns (int192);
}
