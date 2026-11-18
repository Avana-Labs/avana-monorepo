// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAggregatorProxy
/// @notice The aggregator and phase getters of a Chainlink feed proxy.
/// @dev Copied from chainlink-evm `AggregatorProxy.sol` (4d83db2), identical selectors.
interface IAggregatorProxy {
    /// @notice Returns the current phase's aggregator address.
    function aggregator() external view returns (address);

    /// @notice Returns the proxy's current phase, the upper 16 bits of every round ID it reports.
    function phaseId() external view returns (uint16);

    /// @notice Returns the aggregator of a phase.
    function phaseAggregators(
        uint16 phaseId_
    ) external view returns (address);
}
