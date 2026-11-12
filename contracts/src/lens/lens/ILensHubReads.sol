// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILensHubReads
/// @notice The Aave V4 Hub views the Lens reads beyond Avana's minimal `IAaveV4Hub` (same ABI as the pinned release).
/// @custom:spec REQ-LENS-017, REQ-LENS-035, REQ-LENS-036
interface ILensHubReads {
    /// @notice Current drawn index of `assetId`, RAY.
    function getAssetDrawnIndex(
        uint256 assetId
    ) external view returns (uint256 index);

    /// @notice Current drawn rate of `assetId`, RAY per year.
    function getAssetDrawnRate(
        uint256 assetId
    ) external view returns (uint256 rate);

    /// @notice Assets of `shares` added shares, rounded down.
    function previewRemoveByShares(
        uint256 assetId,
        uint256 shares
    ) external view returns (uint256 assets);

    /// @notice Drawn and premium debt owed to `assetId`, asset base units.
    function getAssetOwed(
        uint256 assetId
    ) external view returns (uint256 drawn, uint256 premium);
}
