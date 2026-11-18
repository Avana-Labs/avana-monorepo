// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryLogic
/// @notice Identity of a MarketRegistry logic contract.
/// @dev Runs only by delegatecall from the MarketRegistry, after the registry has checked the caller's role.
interface IMarketRegistryLogic {
    /// @notice The logic contract's kind and the hash of its implementation immutables.
    /// @return kind `keccak256` of the logic contract's name.
    /// @return immutablesHash `keccak256(abi.encode(MarketRegistryImmutables))` it was built with.
    function logicConfig() external view returns (bytes32 kind, bytes32 immutablesHash);
}
