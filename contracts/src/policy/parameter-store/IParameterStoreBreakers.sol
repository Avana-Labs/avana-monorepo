// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreBreakers
/// @notice On-chain breaker values of Q-399 the RiskModule reads, with their setters: the deficit freeze threshold per
/// (funding Hub, debt asset) and the gate recovery window. The concentration gate reads `poolShareMaxBpsOf(poolKey)`,
/// default 10,000 bps (off); per-pool cap optional (Q-403). Price drop, seizure, route failures: alerts only.
/// @dev A tightening makes a breaker more sensitive and runs at the short delay (12 hours), or at once by
/// `APPLICATION_RISK_STEWARD`; a loosening makes it less
/// sensitive and runs at the normal delay. Breakers stop new activity only: no exit, liquidation, pending settlement
/// or rescue top-up reads them, so no allowed value can block those paths. Each tighten setter reverts `NotStricter`
/// unless the value is strictly more sensitive, each loosen setter `NotLooser` unless strictly less sensitive, and
/// both `OutOfBounds` outside the bounds; they emit `ParameterTightened` or `ParameterLoosened`. Every view is `view`
/// and never reverts.
/// @custom:spec REQ-PSTORE-016, REQ-PSTORE-030, Q-399
interface IParameterStoreBreakers {
    /// @notice Hub deficit of a debt asset on one CDP Spoke above which the deficit freeze trips (security freeze,
    /// reopened only by an authorized reset).
    /// @param hub The funding Hub whose deficit is measured.
    /// @param asset Debt asset.
    /// @return value Asset base units (10,000 GHO = 10_000e18 for a GHO reserve at launch; a per-reserve
    /// materiality set at listing for other assets), within [0,
    /// `firstLossReserveMinimum` of the asset's First-Loss Reserve]; 0 for an asset with no value written.
    /// @custom:spec REQ-PSTORE-016, SPEC-BRK-004, Q-241, Q-399
    function breakerDeficitMax(
        address hub,
        address asset
    ) external view returns (uint256 value);

    /// @notice Seconds of healthy observations before a temporary gate (`ORACLE`, `POOL_SHARE`, `POOL_DEPTH`) reopens
    /// after its last recorded breach.
    /// @return value Launch 1,800 (a provisional launch setting), within [600, 7,200].
    /// @custom:spec REQ-PSTORE-030, SPEC-BRK-007, Q-399
    function gateRecoverySeconds() external view returns (uint64 value);

    /// @notice Raises `gateRecoverySeconds` (a temporary gate stays closed longer).
    /// @param value New window, seconds, at most 7,200.
    /// @custom:spec REQ-PSTORE-030, REQ-ACCESS-165, Q-399
    function tightenGateRecoverySeconds(
        uint64 value
    ) external;

    /// @notice Lowers `gateRecoverySeconds`.
    /// @dev Example: from 1,800, `loosenGateRecoverySeconds(600)` succeeds and `(300)` reverts `OutOfBounds`.
    /// @param value New window, seconds, at least 600.
    /// @custom:spec REQ-PSTORE-030, REQ-ACCESS-165, Q-399
    function loosenGateRecoverySeconds(
        uint64 value
    ) external;

    /// @notice Lowers a debt asset's `breakerDeficitMax(hub, asset)` (more sensitive); 10,000 GHO for a GHO reserve.
    /// @dev Reverts `UnknownHub` unless the MarketRegistry records `hub`.
    /// @param hub The funding Hub whose deficit is measured.
    /// @param asset Debt asset.
    /// @param value New maximum, asset base units.
    /// @custom:spec REQ-PSTORE-016, REQ-CONFIG-049, REQ-CONFIG-051
    function tightenBreakerDeficitMax(
        address hub,
        address asset,
        uint256 value
    ) external;

    /// @notice Raises a debt asset's `breakerDeficitMax(hub, asset)`; the debt reserve's listing batch writes the first
    /// value.
    /// @dev Reverts `OutOfBounds` above `firstLossReserveMinimum()` of the First-Loss Reserve of any approved debt reserve
    /// of `asset` funded by `hub`, and `UnknownDebtReserve(address(0), 0)` when no approved debt reserve uses `asset`.
    /// @param hub The funding Hub whose deficit is measured.
    /// @param asset Debt asset.
    /// @param value New maximum, asset base units.
    /// @custom:spec REQ-PSTORE-016, REQ-CONFIG-049, REQ-CONFIG-053
    function loosenBreakerDeficitMax(
        address hub,
        address asset,
        uint256 value
    ) external;
}
