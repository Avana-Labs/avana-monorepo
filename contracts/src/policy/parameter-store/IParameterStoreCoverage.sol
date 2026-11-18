// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreCoverage
/// @notice The chain's first-loss coverage ratio: the share of drawn capacity each First-Loss Reserve must hold.
interface IParameterStoreCoverage {
    /// @notice First-loss coverage ratio agreed in the funding ARFC.
    /// @return value bps within [0, 10,000]; 0 until `setCoverageRatioBps` writes it.
    function coverageRatioBps() external view returns (uint16 value);

    /// @notice Sets `coverageRatioBps`, in either direction.
    /// @dev Reverts `OutOfBounds` above 10,000.
    function setCoverageRatioBps(
        uint16 value
    ) external;
}
