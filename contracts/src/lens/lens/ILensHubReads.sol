// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILensHubReads
/// @notice The Aave V4 Hub views the Lens reads beyond Avana's minimal `IAaveV4Hub` (same ABI as the pinned release).
/// @custom:spec REQ-LENS-017, REQ-LENS-035, REQ-LENS-036, REQ-LENS-052, REQ-LENS-058, REQ-LENS-059
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

    /// @notice Drawn shares of `amount` drawn, rounded up (what `draw` adds).
    function previewDrawByAssets(
        uint256 assetId,
        uint256 amount
    ) external view returns (uint256 shares);

    /// @notice Drawn shares of `amount` restored, rounded down (what `restore` removes).
    function previewRestoreByAssets(
        uint256 assetId,
        uint256 amount
    ) external view returns (uint256 shares);

    /// @notice Total owed (drawn plus premium) of `assetId`, base units.
    function getAssetTotalOwed(
        uint256 assetId
    ) external view returns (uint256 owed);

    /// @notice Premium shares and premium offset of `assetId` (offset in base units × RAY).
    function getAssetPremiumData(
        uint256 assetId
    ) external view returns (uint256 premiumShares, int256 premiumOffsetRay);

    /// @notice Bad debt of `assetId` across every Spoke, base units × RAY.
    function getAssetDeficitRay(
        uint256 assetId
    ) external view returns (uint256 deficitRay);

    /// @notice Fees accrued and not yet minted to the fee receiver, base units.
    function getAssetAccruedFees(
        uint256 assetId
    ) external view returns (uint256 fees);

    /// @notice Liquidity moved out by the reinvestment controller, base units.
    function getAssetSwept(
        uint256 assetId
    ) external view returns (uint256 swept);

    /// @notice Drawn and premium debt `spoke` owes on `assetId`, base units.
    function getSpokeOwed(
        uint256 assetId,
        address spoke
    ) external view returns (uint256 drawn, uint256 premium);

    /// @notice Drawn shares of `spoke` on `assetId`.
    function getSpokeDrawnShares(
        uint256 assetId,
        address spoke
    ) external view returns (uint256 shares);

    /// @notice Premium shares and premium offset of `spoke` on `assetId`.
    function getSpokePremiumData(
        uint256 assetId,
        address spoke
    ) external view returns (uint256 premiumShares, int256 premiumOffsetRay);
}
