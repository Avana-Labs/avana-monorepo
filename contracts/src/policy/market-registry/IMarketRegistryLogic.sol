// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryLogic
/// @notice Identity of a MarketRegistry logic contract.
/// @dev A logic contract holds the bodies of some MarketRegistry setters and runs only by delegatecall from the
/// MarketRegistry, in the registry's ERC-7201 storage and after the registry has checked the caller's role. Called
/// directly, every body reverts (`address(this)` is the logic contract itself), so it holds no state any contract
/// reads.
/// @custom:spec REQ-CONFIG-001, REQ-CONFIG-002
interface IMarketRegistryLogic {
    /// @notice The logic contract's kind and the hash of its implementation immutables.
    /// @return kind `keccak256` of the logic contract's name, for example `keccak256("MarketRegistryHubsLogic")`.
    /// @return immutablesHash `keccak256(abi.encode(MarketRegistryImmutables))` of the values it was built with.
    /// @custom:spec REQ-CONFIG-005
    function logicConfig() external view returns (bytes32 kind, bytes32 immutablesHash);
}
