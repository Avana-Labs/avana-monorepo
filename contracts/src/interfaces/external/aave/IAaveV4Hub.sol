// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveV4Hub
/// @notice Calls Avana makes on an Aave V4 Hub: the Avana Stable LP Hub that lists each market's vault token, and the
/// funding Hubs of the debt assets.
/// @dev ABI checked against `src/hub/interfaces/IHubBase.sol` and `src/hub/interfaces/IHub.sol` of the pinned Aave V4
/// dependency (`a3ef63e`): every selector, struct layout and event signature here equals the Hub's.
interface IAaveV4Hub {
    /// @notice Change to a Spoke's premium accounting carried by a Hub call.
    /// @dev `sharesDelta` is the change in premium shares; `offsetRayDelta` the change in premium offset, in asset units
    /// scaled by 1e27; `restoredPremiumRay` the premium repaid, in asset units scaled by 1e27.
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
    /// @dev `addCap` and `drawCap` count whole asset units, and `MAX_ALLOWED_SPOKE_CAP` means uncapped;
    /// `riskPremiumThreshold` is in basis points, and `MAX_RISK_PREMIUM_THRESHOLD` means no threshold.
    struct SpokeConfig {
        uint40 addCap;
        uint40 drawCap;
        uint24 riskPremiumThreshold;
        bool active;
        bool halted;
    }

    /// @notice A Spoke added `amount` of asset `assetId` for `shares` added shares.
    /// @dev Expected by the Coverage Spoke tests when a Coverage Spoke deposits.
    event Add(uint256 indexed assetId, address indexed spoke, uint256 shares, uint256 amount);

    /// @notice Credits `amount` of asset `assetId`, already transferred to the Hub, to the calling Spoke.
    /// @dev Called by the Coverage Spoke.
    /// @return Added shares.
    function add(
        uint256 assetId,
        uint256 amount
    ) external returns (uint256);

    /// @notice Debits `amount` of asset `assetId` from the calling Spoke and sends it to `to`.
    /// @dev Called by the Coverage Spoke.
    /// @return Removed shares.
    function remove(
        uint256 assetId,
        uint256 amount,
        address to
    ) external returns (uint256);

    /// @notice Burns up to `amount` of the calling Spoke's added asset to cancel `spoke`'s deficit in asset `assetId`.
    /// @dev Called by the Coverage Spoke.
    /// @return Added shares burned.
    /// @return Deficit cancelled, in asset units.
    function eliminateDeficit(
        uint256 assetId,
        uint256 amount,
        address spoke
    ) external returns (uint256, uint256);

    /// @notice Asset ID of `underlying`; reverts when it is not listed.
    /// @dev Read by Collateralization, the MarketRegistry and the ParameterStore.
    function getAssetId(
        address underlying
    ) external view returns (uint256);

    /// @notice Underlying token and decimals of asset `assetId`.
    /// @dev Read by the Coverage Spoke.
    function getAssetUnderlyingAndDecimals(
        uint256 assetId
    ) external view returns (address, uint8);

    /// @notice Total amount of asset `assetId` added across all Spokes.
    /// @dev Read by Collateralization for the vault token's share price.
    function getAddedAssets(
        uint256 assetId
    ) external view returns (uint256);

    /// @notice Total added shares of asset `assetId` across all Spokes.
    /// @dev Read by Collateralization for the vault token's share price.
    function getAddedShares(
        uint256 assetId
    ) external view returns (uint256);

    /// @notice Added shares that `assets` of asset `assetId` would mint now, rounded down.
    /// @dev Read by LPVaultSwap's `settlePending`, which funds a Coverage Spoke only when the amount is worth at least
    /// one share and carries it otherwise (REQ-SWAP-070).
    function previewAddByAssets(
        uint256 assetId,
        uint256 assets
    ) external view returns (uint256);

    /// @notice Total drawn shares of asset `assetId`.
    /// @dev Read by the RiskModule drift check, which requires zero for a vault-token asset.
    function getAssetDrawnShares(
        uint256 assetId
    ) external view returns (uint256);

    /// @notice Amount of asset `assetId` held by the Hub and free to draw or remove.
    /// @dev Read by the Coverage Spoke and Aave V4 integration tests.
    function getAssetLiquidity(
        uint256 assetId
    ) external view returns (uint256);

    /// @notice Amount of asset `assetId` added by `spoke`.
    /// @dev Read by the Coverage Spoke.
    function getSpokeAddedAssets(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);

    /// @notice Added shares of asset `assetId` held by `spoke`.
    /// @dev Read by the Coverage Spoke.
    function getSpokeAddedShares(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);

    /// @notice Total amount of asset `assetId` that `spoke` owes the Hub.
    /// @dev Read by the MarketRegistry.
    function getSpokeTotalOwed(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);

    /// @notice Deficit of `spoke` in asset `assetId`, in asset units scaled by 1e27.
    /// @dev Read by the Coverage Spoke and the MarketRegistry.
    function getSpokeDeficitRay(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);

    /// @notice Settings of asset `assetId`.
    /// @dev Read by the MarketRegistry and the RiskModule drift check.
    function getAssetConfig(
        uint256 assetId
    ) external view returns (AssetConfig memory);

    /// @notice Number of Spokes listed for asset `assetId`.
    /// @dev Read by the Aave V4 fixture tests.
    function getSpokeCount(
        uint256 assetId
    ) external view returns (uint256);

    /// @notice Whether `spoke` is listed for asset `assetId`.
    /// @dev Read by the Coverage Spoke.
    function isSpokeListed(
        uint256 assetId,
        address spoke
    ) external view returns (bool);

    /// @notice Spoke at position `index` in asset `assetId`'s Spoke list.
    /// @dev Read by the RiskModule drift check.
    function getSpokeAddress(
        uint256 assetId,
        uint256 index
    ) external view returns (address);

    /// @notice Settings of `spoke` for asset `assetId`.
    /// @dev Read by the MarketRegistry, the ParameterStore and the RiskModule drift check.
    function getSpokeConfig(
        uint256 assetId,
        address spoke
    ) external view returns (SpokeConfig memory);

    /// @notice Largest underlying decimals the Hub lists, inclusive.
    /// @dev Read by the MarketRegistry.
    function MAX_ALLOWED_UNDERLYING_DECIMALS() external view returns (uint8);

    /// @notice Smallest underlying decimals the Hub lists, inclusive.
    /// @dev Read by the MarketRegistry.
    function MIN_ALLOWED_UNDERLYING_DECIMALS() external view returns (uint8);

    /// @notice The `addCap` or `drawCap` value that means uncapped.
    /// @dev Read by the MarketRegistry and the ParameterStore.
    function MAX_ALLOWED_SPOKE_CAP() external view returns (uint40);

    /// @notice The `riskPremiumThreshold` value, in basis points, that means no threshold.
    /// @dev Read by the RiskModule and the test fixtures.
    function MAX_RISK_PREMIUM_THRESHOLD() external view returns (uint24);
}
