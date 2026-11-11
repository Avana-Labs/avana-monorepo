// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IRiskModuleLogic
/// @notice Identity of a RiskModule logic contract.
/// @dev A logic contract holds some RiskModule check bodies. It is stateless: the RiskModule calls it, and anyone may,
/// and its only state-changing calls are LPOracle and DebtOracle `poke()` (REQ-RISK-003). It never calls
/// `MarketRegistry.recordBreach`, which only the RiskModule proxy may call.
/// @custom:spec REQ-RISK-002, REQ-RISK-003
interface IRiskModuleLogic {
    /// @notice The logic contract's kind and the hash of its implementation immutables.
    /// @return kind `keccak256` of the logic contract's name, for example `keccak256("RiskModuleDriftLogic")`.
    /// @return immutablesHash `keccak256(abi.encode(RiskModuleImmutables))` of the values it was built with.
    /// @custom:spec REQ-RISK-002
    function logicConfig() external view returns (bytes32 kind, bytes32 immutablesHash);
}
