// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPOracleRouter
/// @notice The LPOracle implementation's access to its logic contracts.
interface ILPOracleRouter {
    /// @notice The poke logic contract.
    function POKE_LOGIC() external view returns (address logic);

    /// @notice The listing logic contract.
    function LISTING_LOGIC() external view returns (address logic);

    /// @notice The initialization logic contract (`initialize`'s market part).
    function INIT_LOGIC() external view returns (address logic);

    /// @notice The view logic contract.
    function VIEW_LOGIC() external view returns (address logic);
}
