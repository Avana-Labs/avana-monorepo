// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreLogic
/// @notice Identity of one of the five logic contracts the ParameterStore delegatecalls for its setters.
/// @dev Setter bodies run only by delegatecall from the ParameterStore and revert `NotDelegated` otherwise.
interface IParameterStoreLogic {
    /// @notice The logic contract's kind and implementation immutables.
    /// @return kind `keccak256` of the logic contract's name.
    function logicConfig() external view returns (bytes32 kind, address marketRegistry, uint32 chainBlockTime);
}
