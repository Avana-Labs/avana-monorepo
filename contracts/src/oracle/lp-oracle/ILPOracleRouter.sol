// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPOracleRouter
/// @notice The LPOracle implementation's access to its logic contracts.
/// @custom:spec REQ-ORACLE-106, REQ-ORACLE-078, REQ-ORACLE-080
interface ILPOracleRouter {
    /// @notice The poke logic contract (implementation immutable).
    /// @return logic Address.
    /// @custom:spec REQ-ORACLE-080
    function POKE_LOGIC() external view returns (address logic);

    /// @notice The listing logic contract (implementation immutable).
    /// @return logic Address.
    /// @custom:spec REQ-ORACLE-080
    function LISTING_LOGIC() external view returns (address logic);

    /// @notice The initialization logic contract (implementation immutable): `initialize`'s market part.
    /// @return logic Address (the listing logic where both fit one contract).
    /// @custom:spec REQ-ORACLE-080
    function INIT_LOGIC() external view returns (address logic);

    /// @notice The view logic contract (implementation immutable).
    /// @return logic Address.
    /// @custom:spec REQ-ORACLE-080
    function VIEW_LOGIC() external view returns (address logic);
}
