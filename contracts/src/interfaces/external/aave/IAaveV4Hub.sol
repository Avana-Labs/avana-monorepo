// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveV4Hub
/// @notice Calls Avana makes on an Aave V4 Hub.
/// @dev ABI-equal to the pinned Aave V4 `IHubBase` and `IHub` (`a3ef63e`).
interface IAaveV4Hub {
    /// @notice Change to a Spoke's premium accounting carried by a Hub call.
    /// @dev `offsetRayDelta` and `restoredPremiumRay` are in asset units scaled by 1e27.
    struct PremiumDelta {
        int256 sharesDelta;
        int256 offsetRayDelta;
        uint256 restoredPremiumRay;
    }

    /// @notice Per-asset settings Avana's drift checks compare with the approved listing.
    /// @dev `liquidityFee` is in basis points; `reinvestmentController` must be zero for a vault-token asset.
    struct AssetConfig {
        address feeReceiver;
        uint16 liquidityFee;
        address irStrategy;
        address reinvestmentController;
    }

    /// @notice Per-(asset, Spoke) settings.
    /// @dev Caps count whole asset units; `MAX_ALLOWED_SPOKE_CAP` means uncapped.
    struct SpokeConfig {
        uint40 addCap;
        uint40 drawCap;
        uint24 riskPremiumThreshold;
        bool active;
        bool halted;
    }

    /// @notice A Spoke added `amount` of asset `assetId` for `shares` added shares.
    event Add(uint256 indexed assetId, address indexed spoke, uint256 shares, uint256 amount);

    /// @notice Credits `amount` of asset `assetId`, already transferred to the Hub, to the calling Spoke.
    /// @return Added shares.
    function add(
        uint256 assetId,
        uint256 amount
    ) external returns (uint256);

    /// @notice Debits `amount` of asset `assetId` from the calling Spoke and sends it to `to`.
    /// @return Removed shares.
    function remove(
        uint256 assetId,
        uint256 amount,
        address to
    ) external returns (uint256);

    /// @notice Burns up to `amount` of the calling Spoke's added asset to cancel `spoke`'s deficit in asset `assetId`.
    /// @return Added shares burned.
    /// @return Deficit cancelled, in asset units.
    function eliminateDeficit(
        uint256 assetId,
        uint256 amount,
        address spoke
    ) external returns (uint256, uint256);

    /// @notice Asset ID of `underlying`; reverts when it is not listed.
    function getAssetId(
        address underlying
    ) external view returns (uint256);

    /// @notice Underlying token and decimals of asset `assetId`.
    function getAssetUnderlyingAndDecimals(
        uint256 assetId
    ) external view returns (address, uint8);

    /// @notice Total amount of asset `assetId` added across all Spokes.
    function getAddedAssets(
        uint256 assetId
    ) external view returns (uint256);

    /// @notice Total added shares of asset `assetId` across all Spokes.
    function getAddedShares(
        uint256 assetId
    ) external view returns (uint256);

    /// @notice Added shares that `assets` of asset `assetId` would mint now, rounded down.
    function previewAddByAssets(
        uint256 assetId,
        uint256 assets
    ) external view returns (uint256);

    /// @notice Total drawn shares of asset `assetId`.
    function getAssetDrawnShares(
        uint256 assetId
    ) external view returns (uint256);

    /// @notice Amount of asset `assetId` held by the Hub and free to draw or remove.
    function getAssetLiquidity(
        uint256 assetId
    ) external view returns (uint256);

    /// @notice Amount of asset `assetId` added by `spoke`.
    function getSpokeAddedAssets(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);

    /// @notice Added shares of asset `assetId` held by `spoke`.
    function getSpokeAddedShares(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);

    /// @notice Total amount of asset `assetId` that `spoke` owes the Hub.
    function getSpokeTotalOwed(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);

    /// @notice Deficit of `spoke` in asset `assetId`, in asset units scaled by 1e27.
    function getSpokeDeficitRay(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);

    /// @notice Settings of asset `assetId`.
    function getAssetConfig(
        uint256 assetId
    ) external view returns (AssetConfig memory);

    /// @notice Number of Spokes listed for asset `assetId`.
    function getSpokeCount(
        uint256 assetId
    ) external view returns (uint256);

    /// @notice Whether `spoke` is listed for asset `assetId`.
    function isSpokeListed(
        uint256 assetId,
        address spoke
    ) external view returns (bool);

    /// @notice Whether `underlying` is listed as an asset of the Hub.
    function isUnderlyingListed(
        address underlying
    ) external view returns (bool);

    /// @notice Spoke at position `index` in asset `assetId`'s Spoke list.
    function getSpokeAddress(
        uint256 assetId,
        uint256 index
    ) external view returns (address);

    /// @notice Settings of `spoke` for asset `assetId`.
    function getSpokeConfig(
        uint256 assetId,
        address spoke
    ) external view returns (SpokeConfig memory);

    /// @notice Largest underlying decimals the Hub lists, inclusive.
    function MAX_ALLOWED_UNDERLYING_DECIMALS() external view returns (uint8);

    /// @notice Smallest underlying decimals the Hub lists, inclusive.
    function MIN_ALLOWED_UNDERLYING_DECIMALS() external view returns (uint8);

    /// @notice The `addCap` or `drawCap` value that means uncapped.
    function MAX_ALLOWED_SPOKE_CAP() external view returns (uint40);

    /// @notice The `riskPremiumThreshold` value, in basis points, that means no threshold.
    function MAX_RISK_PREMIUM_THRESHOLD() external view returns (uint24);
}
