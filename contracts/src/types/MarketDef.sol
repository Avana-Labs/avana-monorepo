// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionShape} from "./PositionShape.sol";

/// @notice Input of the MarketRegistry's `listCollateralMarket`.
/// @dev Exactly one of `pool` and `poolId` is set.
struct MarketDef {
    // Hub the market's CDP Spoke draws from.
    address hub;
    // CDP Spoke that lists the market as a collateral reserve.
    address spoke;
    // AMM integration identifier (the AMM protocol's LPVault on this chain).
    uint32 integrationId;
    // Pool address, or address(0) for an AMM protocol keyed by identifier.
    address pool;
    // Pool identifier, or bytes32(0) for an AMM protocol keyed by address.
    bytes32 poolId;
    PositionShape shape;
    // Vault token deployed by the VaultTokenFactory for the market.
    address vaultToken;
    // The market's seeded LPOracle feed proxy.
    address lpOracle;
    // Integration-specific listing data, decoded and checked by the integration.
    bytes integrationData;
}
