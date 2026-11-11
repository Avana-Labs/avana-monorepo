// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAggregatorProxy
/// @notice The aggregator and phase getters of a Chainlink feed proxy, copied from `contracts/src/v0.6/data-feeds/AggregatorProxy.sol`
/// of smartcontractkit/chainlink-evm at commit 4d83db28afc6d54761ce324e633d89244a97907e (inherited unchanged by
/// `EACAggregatorProxy.sol`), with identical selectors. `phaseId()` is the proxy's `external view` function returning
/// `currentPhase.id`; `phaseAggregators` is the public getter of its `phaseAggregators` mapping.
/// @dev Called by: ParameterStore (`setFeed`); LPOracle and DebtOracle (recovery evidence across a phase change).
interface IAggregatorProxy {
    /// @notice Returns the current phase's aggregator address. Source:
    /// `contracts/src/v0.6/data-feeds/AggregatorProxy.sol` (chainlink-evm 4d83db2).
    /// @dev Called by: ParameterStore, in `setFeed`, to read the aggregator's answer bounds.
    function aggregator() external view returns (address);

    /// @notice Returns the proxy's current phase, the upper 16 bits of every round ID it reports. Source:
    /// `contracts/src/v0.6/data-feeds/AggregatorProxy.sol` (chainlink-evm 4d83db2), `function phaseId() external view returns (uint16)`.
    /// @dev Called by: LPOracle and DebtOracle when a leg's round is the first of a phase.
    /// @custom:spec REQ-ORACLE-089, SPEC-ORC-014, Q-272
    function phaseId() external view returns (uint16);

    /// @notice Returns the aggregator of a phase. Source: `contracts/src/v0.6/data-feeds/AggregatorProxy.sol`
    /// (chainlink-evm 4d83db2), `mapping(uint16 => AggregatorV2V3Interface) public phaseAggregators`.
    /// @dev Called by: LPOracle and DebtOracle, with `phaseId - 1`, to read the previous phase's last round.
    /// @custom:spec REQ-ORACLE-089, SPEC-ORC-014, Q-272
    function phaseAggregators(
        uint16 phaseId_
    ) external view returns (address);
}
