// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryCreditLines
/// @notice Credit-line registry: per (funding Hub, asset), the recorded line and the sum of the Spokes' draw caps.
/// @dev Lines and draw caps are in whole tokens; coverage is tested on the line, not on the sum.
interface IMarketRegistryCreditLines {
    /// @notice A line or a Spoke's draw cap was recorded.
    /// @param spoke CDP Spoke whose draw cap was read (`address(0)` for a line change).
    /// @param drawCap The Spoke's draw cap, whole tokens (`2^128` for an unbounded cap).
    event CreditLineRecorded(
        address indexed hub, address indexed asset, address indexed spoke, uint256 drawCap, uint256 sum
    );

    event CreditLineSet(address indexed hub, address indexed asset, uint256 line, uint256 sum);

    /// @notice The draw caps on `(hub, asset)` would exceed the recorded line.
    error CreditLineExceeded(address hub, address asset, uint256 sum, uint256 line);

    /// @notice The First-Loss Reserve of `(hub, asset)` is below the coverage ratio for the line.
    error CoverageBelowRatio(address hub, address asset, uint256 required, uint256 funded);

    /// @notice A debt reserve names a First-Loss Reserve other than `firstLossReserveOf(hub, asset)`.
    error AvanaFirstLossReserveMismatch(address hub, address asset, address firstLossReserve);

    /// @notice The First-Loss Reserve of `(hub, asset)` holds less than its `firstLossReserveMinimum`.
    error CoverageNotFunded(address hub, address asset);

    /// @notice A cross-Hub reserve was enabled before the funding Hub's governance recorded a line.
    error FundingHubConsentMissing(address hub, address asset);

    /// @notice Records the line of `(fundingHub, asset)` that the funding Hub's governance approved.
    /// @dev `APPLICATION_ADMIN` only. The line must cover `drawCapSum` and be covered by the First-Loss Reserve.
    function recordCreditLine(
        address fundingHub,
        address asset,
        uint256 line
    ) external;

    /// @notice Re-reads a Spoke's live `drawCap` for one debt reserve and recomputes `drawCapSum`.
    /// @dev Callable by anyone. Records the live cap regardless of coverage or line, so a raise is never hidden.
    function syncDrawCap(
        address spoke,
        uint256 debtReserveId
    ) external;

    /// @notice The recorded line and draw-cap sum of `(fundingHub, asset)`.
    function creditLine(
        address fundingHub,
        address asset
    ) external view returns (uint256 line, uint256 drawCapSum);

    /// @notice First-loss coverage of the line of `(fundingHub, asset)`.
    /// @dev Covered when `required <= funded`; `required` rounds up. The RiskModule gates cross-Hub borrows on it.
    /// @return required Balance the line requires, base units.
    /// @return funded First-Loss Reserve balance, base units.
    function creditLineCoverage(
        address fundingHub,
        address asset
    ) external view returns (uint256 required, uint256 funded);
}
