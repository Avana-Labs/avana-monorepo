// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveAdapterLogic
/// @notice Identity of an AaveAdapter logic contract.
/// @dev Runs only by `delegatecall` from the Adapter, in the Adapter's storage; a direct call reverts `NotDelegated`.
interface IAaveAdapterLogic {
    /// @notice The logic contract's kind and the hash of its implementation immutables.
    /// @return kind `keccak256` of the logic contract's name.
    function logicConfig() external view returns (bytes32 kind, bytes32 immutablesHash);
}
