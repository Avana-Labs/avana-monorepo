// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveAdapterLogic
/// @notice Identity of an AaveAdapter logic contract.
/// @dev A logic contract holds the bodies of some Adapter entry points and runs only by `delegatecall` from the
/// Adapter, in the Adapter's ERC-7201 storage and with the Adapter's address as `address(this)`. Called directly, every
/// body reverts `NotDelegated()`, so it holds no state and moves nothing of its own.
/// @custom:spec REQ-ADAPTER-004
interface IAaveAdapterLogic {
    /// @notice The logic contract's kind and the hash of its implementation immutables.
    /// @return kind `keccak256` of the logic contract's name, for example `keccak256("AaveAdapterUserLogic")`.
    /// @return immutablesHash `keccak256(abi.encode(AaveAdapterImmutables))` of the values it was built with.
    /// @custom:spec REQ-ADAPTER-004
    function logicConfig() external view returns (bytes32 kind, bytes32 immutablesHash);
}
