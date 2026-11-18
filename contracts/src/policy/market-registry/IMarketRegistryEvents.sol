// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PauseState} from "../../types/PauseState.sol";

/// @title IMarketRegistryEvents
/// @notice Events of the MarketRegistry's Spoke, debt-reserve, token, market lifecycle, route and pause writes.
interface IMarketRegistryEvents {
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
    event PriceSourceSet(address token, address[] primaryRoute, address[] alternateRoute, address[] standbyRoute);

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

    /// @notice A Hub's pause state changed.
    event PauseStateChanged(
        address indexed hub, PauseState indexed previous, PauseState indexed current, address caller
    );
}
