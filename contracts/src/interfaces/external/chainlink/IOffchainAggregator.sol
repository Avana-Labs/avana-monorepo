// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IOffchainAggregator
/// @notice The answer bounds of a Chainlink OCR aggregator.
/// @dev ABI-identical getters of the `int192 immutable public` bounds in smartcontractkit/libocr (199a6f1).
interface IOffchainAggregator {
    /// @notice Returns the lowest answer the aggregator accepts.
    function minAnswer() external view returns (int192);

    /// @notice Returns the highest answer the aggregator accepts.
    function maxAnswer() external view returns (int192);
}
