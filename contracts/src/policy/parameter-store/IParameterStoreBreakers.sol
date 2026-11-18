// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreBreakers
/// @notice Circuit-breaker values the RiskModule reads: the deficit freeze threshold and the gate recovery window.
/// @dev Breakers stop new activity only; no exit or liquidation path reads them.
interface IParameterStoreBreakers {
    /// @notice Hub deficit of a debt asset above which the deficit freeze trips.
    /// @return value Asset base units; 0 when none is written.
    function breakerDeficitMax(
        address hub,
        address asset
    ) external view returns (uint256 value);

    /// @notice Seconds of healthy observations before a temporary gate reopens after its last breach.
    function gateRecoverySeconds() external view returns (uint64 value);

    /// @notice Raises `gateRecoverySeconds` (a temporary gate stays closed longer).
    function tightenGateRecoverySeconds(
        uint64 value
    ) external;

    /// @notice Lowers `gateRecoverySeconds`.
    function loosenGateRecoverySeconds(
        uint64 value
    ) external;

    /// @notice Lowers a debt asset's `breakerDeficitMax(hub, asset)` (more sensitive).
    /// @dev Reverts `UnknownHub` unless the MarketRegistry records `hub`.
    /// @param value New maximum, asset base units.
    function tightenBreakerDeficitMax(
        address hub,
        address asset,
        uint256 value
    ) external;

    /// @notice Raises a debt asset's `breakerDeficitMax(hub, asset)`.
    /// @dev Reverts `OutOfBounds` above the `firstLossReserveMinimum()` of a matching debt reserve.
    /// @param value New maximum, asset base units.
    function loosenBreakerDeficitMax(
        address hub,
        address asset,
        uint256 value
    ) external;
}
