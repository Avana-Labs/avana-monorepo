// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {HubAssetExposureView, TailCoverageView} from "./types/LensTypes.sol";

/// @title ILensRisk
/// @notice Risk views of the Lens: breaker status, tail coverage and Hub asset exposure.
interface ILensRisk {
    /// @notice Returns the reasons of a market's circuit breaker that hold now, passed through from the RiskModule.
    function getBreakerStatus(
        uint256 marketId
    ) external view returns (uint32 reasons);

    /// @notice Returns the reasons of a debt reserve's circuit breaker that hold now, passed through from the
    /// RiskModule.
    function getDebtBreakerStatus(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32 reasons);

    /// @notice Returns a First-Loss Reserve's funded balance against its largest one-token tail exposure.
    /// @dev Rounding never overstates coverage.
    function getTailCoverage(
        address hub,
        address debtAsset
    ) external view returns (TailCoverageView memory coverage);

    /// @notice Hub deficit of `(hub, asset)` above what the First-Loss Reserve and DAO offset hold, base units.
    /// @return uncovered `max(0, deficit - fundedBalance - offsetFunded)`.
    function uncoveredDeficit(
        address hub,
        address asset
    ) external view returns (uint256 uncovered);

    /// @notice Exposure of `(hub, asset)` across every Spoke drawing on it, with its coverage check.
    function getHubAssetExposure(
        address hub,
        address asset
    ) external view returns (HubAssetExposureView memory view_);
}
