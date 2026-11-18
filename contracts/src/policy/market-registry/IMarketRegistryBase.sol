// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryBase
/// @notice Errors and events of the MarketRegistry, shared with its logic contracts.
interface IMarketRegistryBase {
    /// @notice A write would map a pool, vault token, LPOracle, Hub asset or Spoke reserve to a second market.
    error DuplicateMarketKey();

    /// @notice A restore named an address never set for that slot through the governance role.
    error NotPreviouslyApproved();

    error InvalidRoute();

    /// @notice A debt asset charges a non-zero transfer fee at listing (its issuer probe reads a fee rate above 0).
    error TransferFeeActive(address asset);

    error UnknownMarket(uint256 marketId);

    error MarketNotRegistered(uint256 marketId);

    error MarketNotActive(uint256 marketId);

    error TokenNotListed(address token);

    /// @notice The Spoke is not approved, or failed the `approveSpoke` checks.
    error InvalidSpoke(address spoke);

    /// @notice The vault token does not match the factory registry or the market definition.
    error VaultTokenMismatch();

    error ListingCheckFailed(bytes32 check);

    error ActivationCheckFailed(uint256 marketId, bytes32 check);

    error UnknownDebtReserve(address spoke, uint256 reserveId);

    /// @notice The debt reserve still has debt owed or an uncovered deficit.
    error DebtReserveInUse(address spoke, uint256 reserveId);

    error InvalidDebtReserve(bytes32 check);

    /// @notice A logic contract body was called directly instead of by delegatecall.
    error Unauthorized(address caller);

    /// @notice Liquidation of this (market, debt reserve) pair would have no usable swap route or flash source.
    error LivenessBound(address spoke, uint256 marketId, uint256 debtReserveId);

    /// @notice A new market would take the registry past `MAX_MARKET_COUNT` listings.
    error MarketCountLimit(uint256 limit);

    /// @notice Emitted by `deployCdpSpoke`.
    event SpokeApproved(
        address indexed spoke,
        address indexed hub,
        uint32 indexed integrationId,
        address implementation,
        address aaveOracle
    );

    /// @notice Emitted by `enableDebtReserve`.
    event DebtReserveApproved(
        address indexed spoke,
        uint256 indexed reserveId,
        address asset,
        address fundingHub,
        uint256 hubAssetId,
        address priceSource,
        address firstLossReserve
    );

    /// @notice Emitted by `removeDebtReserve`.
    event DebtReserveRemoved(address indexed spoke, uint256 indexed reserveId);

    /// @notice Emitted by `listToken`.
    /// @param pegModule Peg module (GSM or PSM) a backup swap route must avoid, or address(0).
    event TokenListed(
        address token, uint8 decimals, address[] primaryRoute, address[] alternateRoute, address pegModule
    );

    /// @notice Emitted by `setPriceSource`.
    event PriceSourceSet(address token, address[] primaryRoute, address[] alternateRoute);

    /// @notice Emitted by `listCollateralMarket`.
    /// @param pool Pool address (address(0) for an AMM protocol keyed by identifier).
    /// @param poolId Pool identifier (bytes32(0) for an AMM protocol keyed by address).
    /// @param tokens Pool tokens in pool order.
    event MarketRegistered(
        uint256 indexed marketId,
        uint32 indexed integrationId,
        address pool,
        bytes32 poolId,
        address[] tokens,
        address vaultToken,
        address lpOracle,
        address indexed spoke
    );

    /// @notice Emitted by `activateMarket`; `(chainId, spoke, reserveId)` is the external market key.
    event MarketActivated(
        uint256 marketId, uint256 chainId, address spoke, uint256 reserveId, address hub, uint256 hubAssetId
    );

    /// @notice Emitted by `cancelRegistration`.
    event MarketRegistrationCancelled(uint256 marketId);

    /// @notice Emitted by `setMarketOffboarding`.
    event MarketOffboarding(uint256 marketId);

    /// @notice Emitted by `setRoute`.
    /// @param kind 0 primary, 1 backup.
    event RouteSet(uint256 indexed marketId, address token, address debtAsset, uint8 kind, address route);

    /// @notice Emitted by `disableRoute`.
    /// @param kind 0 primary, 1 backup.
    event RouteDisabled(uint256 indexed marketId, address token, address debtAsset, uint8 kind, address caller);

    /// @notice Emitted by `restoreRoute`.
    /// @param kind 0 primary, 1 backup.
    event RouteRestored(uint256 indexed marketId, address token, address debtAsset, uint8 kind, address route);
}
