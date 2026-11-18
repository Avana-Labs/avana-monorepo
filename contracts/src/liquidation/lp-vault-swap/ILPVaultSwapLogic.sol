// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPVaultSwapLogic
/// @notice Identity of an LPVaultSwap logic contract.
/// @dev Runs only by delegatecall from the LPVaultSwap implementation; called directly, it reverts `NotDelegated`.
interface ILPVaultSwapLogic {
    /// @notice The logic contract's kind and the hash of its implementation immutables.
    function logicConfig() external view returns (bytes32 kind, bytes32 immutablesHash);
}
