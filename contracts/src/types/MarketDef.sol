// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionShape} from "./PositionShape.sol";

/// @notice Input of `listCollateralMarket` (MarketRegistry `registerMarket`).
/// @dev A market is one (chain, AMM protocol, pool, exact position shape). The tokens, their order and decimals are
/// read on-chain through `IAmmIntegration.poolTokens`, never from the input. Pool-specific settings (fee tier, tick
/// spacing, Slipstream factory generation, Curve rate providers) are read and stored by the AMM integration in its
/// own per-market configuration, validated by `IAmmIntegration.validateMarket(pool, poolId, shape, integrationData)`.
/// Exactly one of `pool` and `poolId` is set, as the integration's `poolKeying` requires: an address for Uniswap v3,
/// Slipstream, Uniswap v2 and Curve; a `bytes32` identifier for Uniswap v4 (`PoolId`) and Balancer (pool id).
/// Market parameters are written in the ParameterStore by `setInitialMarketParams` in the same listing batch.
/// @custom:spec REQ-CONFIG-028, REQ-CONFIG-029, REQ-AMM-CORE-003, REQ-AMM-CORE-010, Q-370, Q-371
struct MarketDef {
    // Hub the market's CDP Spoke draws from (Stable LP, Correlated LP or Volatile LP tier).
    address hub;
    // CDP Spoke that lists the market as a collateral reserve.
    address spoke;
    // AMM integration identifier (the AMM protocol's LPVault on this chain).
    uint32 integrationId;
    // Pool address, or address(0) for an AMM protocol keyed by identifier.
    address pool;
    // Pool identifier, or bytes32(0) for an AMM protocol keyed by address.
    bytes32 poolId;
    // Exact position shape.
    PositionShape shape;
    // Vault token deployed by the VaultTokenFactory for the market.
    address vaultToken;
    // The market's seeded LPOracle feed proxy.
    address lpOracle;
    // Integration-specific listing data, decoded and checked by the integration.
    bytes integrationData;
}
