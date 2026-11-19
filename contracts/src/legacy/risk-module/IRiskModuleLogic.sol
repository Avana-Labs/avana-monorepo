// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IRiskModuleLogic
/// @notice Identity of a LegacyRiskModule logic contract.
/// @dev Stateless; its only state-changing calls are LPOracle and DebtOracle `poke()`.
interface IRiskModuleLogic {
    /// @notice The logic contract's kind and the hash of its implementation immutables.
    /// @return kind `keccak256` of the logic contract's name.
    /// @return immutablesHash `keccak256(abi.encode(RiskModuleImmutables))` it was built with.
    function logicConfig() external view returns (bytes32 kind, bytes32 immutablesHash);
}
