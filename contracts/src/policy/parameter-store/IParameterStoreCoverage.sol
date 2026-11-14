// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreCoverage
/// @notice The chain's first-loss coverage ratio, the share of drawn capacity the Avana Umbrella (First-Loss Reserve) of
/// each (Hub, debt asset) must hold.
/// @dev The MarketRegistry reads `coverageRatioBps()` for the coverage rule `fundedBalance × 10⁴ ≥ coverageRatioBps ×
/// Σ drawCap × 10^dec` (`DEF-019`) at `enableDebtReserve`, `recordCreditLine` and every recorded `drawCap` raise.
/// `setCoverageRatioBps` requires `APPLICATION_ADMIN` and runs through the timelock at the normal delay in either
/// direction; it has no tighten setter. Example (illustrative): at 2,000 bps a 2,000,000 GHO `drawCap` needs a
/// 400,000 GHO funded balance; at 1,500 bps it needs 300,000 GHO.
/// @custom:spec REQ-PSTORE-032, Q-353, Q-391
interface IParameterStoreCoverage {
    /// @notice First-loss coverage ratio agreed in the funding ARFC.
    /// @return value bps within [0, 10,000]; 0 until `setCoverageRatioBps` writes it.
    /// @custom:spec REQ-PSTORE-032
    function coverageRatioBps() external view returns (uint16 value);

    /// @notice Sets `coverageRatioBps`, in either direction.
    /// @dev Normal delay; reverts `OutOfBounds` above 10,000. Emits `ParameterSet`.
    /// @param value New ratio, bps.
    /// @custom:spec REQ-PSTORE-032, REQ-CONFIG-049
    function setCoverageRatioBps(
        uint16 value
    ) external;
}
