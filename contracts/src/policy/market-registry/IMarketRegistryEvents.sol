// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PauseState} from "../../types/PauseState.sol";

/// @title IMarketRegistryEvents
/// @notice Events of the MarketRegistry: Spoke and debt-reserve approval, token listing, market lifecycle, conversion,
/// swap routes and each Hub's pause state.
interface IMarketRegistryEvents {
    /// @notice Emitted by `deployCdpSpoke`.
    /// @param spoke The CDP Spoke.
    /// @param hub Home Hub.
    /// @param integrationId AMM integration of the Spoke's markets.
    /// @param implementation Approved standard Spoke implementation.
    /// @param aaveOracle The Spoke's AaveOracle.
    /// @custom:spec REQ-CONFIG-016, REQ-CONFIG-074, Q-378
    event SpokeApproved(
        address indexed spoke,
        address indexed hub,
        uint32 indexed integrationId,
        address implementation,
        address aaveOracle
    );

    /// @notice Emitted by `enableDebtReserve`.
    /// @param spoke The CDP Spoke.
    /// @param reserveId Debt reserve identifier.
    /// @param asset Debt asset.
    /// @param fundingHub Hub that funds the reserve.
    /// @param hubAssetId Hub asset identifier.
    /// @param priceSource AaveOracle price source.
    /// @param coverageSpoke Coverage Spoke of (fundingHub, asset).
    /// @custom:spec REQ-MREG-006
    event DebtReserveApproved(
        address indexed spoke,
        uint256 indexed reserveId,
        address asset,
        address fundingHub,
        uint256 hubAssetId,
        address priceSource,
        address coverageSpoke
    );

    /// @notice Emitted by `removeDebtReserve`.
    /// @param spoke The CDP Spoke.
    /// @param reserveId Debt reserve identifier.
    /// @custom:spec REQ-MREG-010
    event DebtReserveRemoved(address indexed spoke, uint256 indexed reserveId);

    /// @notice Emitted by `listToken`.
    /// @param token The listed token.
    /// @param decimals Token decimals read on-chain.
    /// @param primaryRoute Primary route feeds.
    /// @param alternateRoute Alternate route feeds.
    /// @param pegModule Peg module (GSM or PSM) a backup swap route must avoid, or address(0).
    /// @custom:spec REQ-CONFIG-017, REQ-CONFIG-021
    event TokenListed(
        address token, uint8 decimals, address[] primaryRoute, address[] alternateRoute, address pegModule
    );

    /// @notice Emitted by `setPriceSource`.
    /// @param token Pool token.
    /// @param primaryRoute New primary route feeds.
    /// @param alternateRoute New alternate route feeds.
    /// @param standbyRoute New standby route feeds.
    /// @custom:spec REQ-CONFIG-026, REQ-CONFIG-027, REQ-MREG-027
    event PriceSourceSet(address token, address[] primaryRoute, address[] alternateRoute, address[] standbyRoute);

    /// @notice Emitted by `listCollateralMarket`.
    /// @param marketId New market identifier.
    /// @param integrationId AMM integration.
    /// @param pool Pool address (address(0) for an AMM protocol keyed by identifier).
    /// @param poolId Pool identifier (bytes32(0) for an AMM protocol keyed by address).
    /// @param tokens Pool tokens in pool order.
    /// @param vaultToken Vault token.
    /// @param lpOracle LPOracle feed.
    /// @param spoke CDP Spoke.
    /// @custom:spec REQ-CONFIG-028, Q-376
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
    /// @param marketId Market identifier.
    /// @param chainId Chain identifier.
    /// @param spoke CDP Spoke.
    /// @param reserveId CDP Spoke reserve identifier.
    /// @param hub Home Hub.
    /// @param hubAssetId Hub asset identifier.
    /// @custom:spec REQ-CONFIG-006, REQ-CONFIG-042
    event MarketActivated(
        uint256 marketId, uint256 chainId, address spoke, uint256 reserveId, address hub, uint256 hubAssetId
    );

    /// @notice Emitted by `cancelRegistration`.
    /// @param marketId Market identifier.
    /// @custom:spec REQ-CONFIG-048
    event MarketRegistrationCancelled(uint256 marketId);

    /// @notice Emitted by `setMarketOffboarding`.
    /// @param marketId Market identifier.
    /// @custom:spec REQ-MREG-015
    event MarketOffboarding(uint256 marketId);

    /// @notice Emitted by `setRoute`.
    /// @param marketId Market identifier.
    /// @param token Pool token sold by the route.
    /// @param debtAsset Debt asset bought by the route.
    /// @param kind 0 primary, 1 backup.
    /// @param route Swap route contract.
    /// @custom:spec REQ-CONFIG-060, Q-379
    event RouteSet(uint256 indexed marketId, address token, address debtAsset, uint8 kind, address route);

    /// @notice Emitted by `disableRoute`.
    /// @param marketId Market identifier.
    /// @param token Pool token.
    /// @param debtAsset Debt asset.
    /// @param kind 0 primary, 1 backup.
    /// @param caller The timelock.
    /// @custom:spec REQ-CONFIG-061
    event RouteDisabled(uint256 indexed marketId, address token, address debtAsset, uint8 kind, address caller);

    /// @notice Emitted by `restoreRoute`.
    /// @param marketId Market identifier.
    /// @param token Pool token.
    /// @param debtAsset Debt asset.
    /// @param kind 0 primary, 1 backup.
    /// @param route Restored route contract.
    /// @custom:spec REQ-CONFIG-062
    event RouteRestored(uint256 indexed marketId, address token, address debtAsset, uint8 kind, address route);

    /// @notice A Hub's pause state changed.
    /// @param hub The Hub whose state changed.
    /// @param previous State before the call.
    /// @param current State after the call.
    /// @param caller Guardian or the timelock.
    /// @custom:spec REQ-MREG-001
    event PauseStateChanged(
        address indexed hub, PauseState indexed previous, PauseState indexed current, address caller
    );
}
