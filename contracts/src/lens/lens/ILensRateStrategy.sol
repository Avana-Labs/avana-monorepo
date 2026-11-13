// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILensRateStrategy
/// @notice The Aave V4 asset interest-rate strategy view the Lens reads (same ABI as the pinned release, a3ef63e).
/// @custom:spec REQ-LENS-046
interface ILensRateStrategy {
    /// @notice Rate-curve parameters of one asset, bps.
    struct InterestRateData {
        uint16 optimalUsageRatio;
        uint32 baseDrawnRate;
        uint32 rateGrowthBeforeOptimal;
        uint32 rateGrowthAfterOptimal;
    }

    /// @notice The rate-curve parameters of `assetId`.
    function getInterestRateData(
        uint256 assetId
    ) external view returns (InterestRateData memory data);
}
