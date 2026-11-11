// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryCreditLines
/// @notice The credit-line registry: per (funding Hub, asset), the line the funding Hub's governance recorded and the
/// sum of the draw caps of every CDP Spoke drawing on it.
/// @dev `drawCapSum` is the sum of `drawCap(fundingHub, asset, s)` over every CDP Spoke `s` with an enabled reserve
/// drawing `(fundingHub, asset)` (2.7 `SPEC-CAP-010`), in whole tokens as Aave V4 records caps; the line is in whole
/// tokens too, and coverage is tested on the line, not on the sum, which the line bounds. A line is covered when `line × 10^dec × coverageRatioBps <=
/// fundedBalance × 1e4`, with `line` in whole tokens, `dec` the asset's decimals, `fundedBalance` the asset balance
/// of `coverageSpokeOf(fundingHub, asset)` and `coverageRatioBps` from the ParameterStore (launch 2,000). Example: a
/// 20,000,000 GHO line at 2,000 bps needs 20,000,000 × 1e18 × 2,000 <= fundedBalance × 1e4, that is a Coverage Spoke
/// balance of at least 4,000,000 GHO. `enableDebtReserve` and `recordCreditLine` run both checks, so no line is recorded
/// above coverage and no reserve is enabled past its line; `syncDrawCap` records the live cap whatever the result, so
/// the recorded sum never hides a raise, and `creditLineCoverage` serves the coverage test to the borrow gate.
/// @custom:spec REQ-CONFIG-081, SPEC-CAP-010, Q-378
interface IMarketRegistryCreditLines {
    /// @notice A line or a Spoke's draw cap was recorded.
    /// @param hub Funding Hub.
    /// @param asset Asset.
    /// @param spoke CDP Spoke whose draw cap was read (`address(0)` for a line change).
    /// @param drawCap The Spoke's draw cap, whole tokens (`2^128` for an unbounded cap).
    /// @param sum New `drawCapSum`, whole tokens.
    /// @custom:spec REQ-CONFIG-081
    event CreditLineRecorded(
        address indexed hub, address indexed asset, address indexed spoke, uint256 drawCap, uint256 sum
    );

    /// @notice A funding Hub's line was recorded.
    /// @param hub Funding Hub.
    /// @param asset Asset.
    /// @param line The new line, whole tokens.
    /// @param sum The current `drawCapSum`, whole tokens.
    /// @custom:spec REQ-CONFIG-081
    event CreditLineSet(address indexed hub, address indexed asset, uint256 line, uint256 sum);

    /// @notice The draw caps on `(hub, asset)` would exceed the recorded line.
    /// @custom:spec REQ-CONFIG-081
    error CreditLineExceeded(address hub, address asset, uint256 sum, uint256 line);

    /// @notice The Coverage Spoke of `(hub, asset)` is below the coverage ratio for the line.
    /// @custom:spec REQ-CONFIG-081
    error CoverageBelowRatio(address hub, address asset, uint256 required, uint256 funded);

    /// @notice A debt reserve names a Coverage Spoke other than `coverageSpokeOf(hub, asset)`.
    /// @custom:spec REQ-CONFIG-081
    error CoverageSpokeMismatch(address hub, address asset, address coverageSpoke);

    /// @notice The Coverage Spoke of `(hub, asset)` holds less than its `firstLossReserveMinimum`.
    /// @custom:spec REQ-CONFIG-081
    error CoverageNotFunded(address hub, address asset);

    /// @notice A cross-Hub reserve was enabled before the funding Hub's governance recorded a line.
    /// @custom:spec REQ-CONFIG-081, Q-378
    error FundingHubConsentMissing(address hub, address asset);

    /// @notice Records the line of `(fundingHub, asset)` that the funding Hub's governance approved.
    /// @dev `APPLICATION_ADMIN`, normal delay. Reverts `CreditLineExceeded` when `drawCapSum` exceeds `line` and
    /// `CoverageBelowRatio` when the Coverage Spoke does not cover it. Emits `CreditLineSet`.
    /// @param fundingHub The funding Hub.
    /// @param asset The asset.
    /// @param line Line, whole tokens.
    /// @custom:spec REQ-CONFIG-081
    function recordCreditLine(
        address fundingHub,
        address asset,
        uint256 line
    ) external;

    /// @notice Re-reads a Spoke's live `drawCap` for one debt reserve and recomputes `drawCapSum`.
    /// @dev Callable by anyone. Always records the live cap and the new sum, whatever the coverage or the line, so a
    /// raise is never hidden: a sum above the line makes every cross-Hub borrow on that line revert
    /// `CreditLineExceeded` until the sum is back under the line, and coverage is a separate gate read through
    /// `creditLineCoverage`. Reverts only `UnknownDebtReserve` for a reserve that is not enabled. Emits
    /// `CreditLineRecorded`.
    /// @param spoke CDP Spoke.
    /// @param debtReserveId Debt reserve.
    /// @custom:spec REQ-CONFIG-081
    function syncDrawCap(
        address spoke,
        uint256 debtReserveId
    ) external;

    /// @notice The recorded line and draw-cap sum of `(fundingHub, asset)`.
    /// @param fundingHub The funding Hub.
    /// @param asset The asset.
    /// @return line Line, whole tokens.
    /// @return drawCapSum Sum of the draw caps, whole tokens.
    /// @custom:spec REQ-CONFIG-081
    function creditLine(
        address fundingHub,
        address asset
    ) external view returns (uint256 line, uint256 drawCapSum);

    /// @notice First-loss coverage of the line of `(fundingHub, asset)`.
    /// @dev `required = ⌈line × 10^dec × coverageRatioBps / 10^4⌉` base units, the smallest Coverage Spoke balance that
    /// covers the line, and `funded`, the asset balance of `coverageSpokeOf(fundingHub, asset)` (0 when the pair has
    /// none); both 0 for a line of 0. The line is covered when `required <= funded`. `recordCreditLine` and
    /// `enableDebtReserve` refuse an uncovered line; the RiskModule reads this view as the coverage gate of a
    /// cross-Hub borrow (`CoverageBelowRatio(fundingHub, asset, required, funded)`), since `syncDrawCap` records every
    /// cap whatever the coverage. Reverts only when a Coverage Spoke, the asset or the ParameterStore read reverts.
    /// Example: a 20,000,000 GHO line at 2,000 bps requires 4×10^24 base units.
    /// @param fundingHub The funding Hub.
    /// @param asset The asset.
    /// @return required Balance the line requires, base units.
    /// @return funded Coverage Spoke balance, base units.
    /// @custom:spec REQ-CONFIG-081, REQ-RISK-082
    function creditLineCoverage(
        address fundingHub,
        address asset
    ) external view returns (uint256 required, uint256 funded);
}
