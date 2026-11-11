// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketStatus} from "../policy/market-registry/types/MarketStatus.sol";
import {PositionShape} from "./PositionShape.sol";

/// @notice Stored market definition.
/// @dev Every field except `hubAssetId`, `reserveId`, `status` and `activatedAt` is immutable after
/// `registerMarket`; `hubAssetId` and `reserveId` are fixed by `activateMarket`. `chainId` equals `block.chainid`
/// at registration. `tokens` is the pool's own token order (for example `token0`, `token1` for a concentrated
/// liquidity pool); every n-token array in Avana (amounts, prices, minimums, counters, routes) uses this order and has
/// length `tokens.length`, between 2 and `MAX_POOL_TOKENS` = 8. Fee tier and tick spacing are not market fields: the
/// AMM integration stores them in its own per-market configuration.
/// @custom:spec REQ-CONFIG-006, REQ-CONFIG-008, REQ-CONFIG-009, REQ-CONFIG-010, REQ-CONFIG-013, REQ-AMM-CORE-002, REQ-AMM-CORE-003, Q-370
struct Market {
    // Chain identifier.
    uint64 chainId;
    // Hub of the market's CDP Spoke.
    address hub;
    // CDP Spoke.
    address spoke;
    // AMM integration identifier.
    uint32 integrationId;
    // AMM integration (the AMM protocol's LPVault on this chain).
    address integration;
    // Pool address (address(0) for an AMM protocol keyed by identifier).
    address pool;
    // Pool identifier (bytes32(0) for an AMM protocol keyed by address).
    bytes32 poolId;
    // Exact position shape.
    PositionShape shape;
    // Pool tokens in pool order.
    address[] tokens;
    // Decimals of each pool token.
    uint8[] tokenDecimals;
    // Vault token of the market.
    address vaultToken;
    // Vault-token decimals, fixed by the integration's unit definition.
    uint8 decimals;
    // The market's LPOracle feed proxy.
    address lpOracle;
    // Hub asset identifier of the vault token (set at activation).
    uint256 hubAssetId;
    // CDP Spoke reserve identifier of the vault token (set at activation).
    uint256 reserveId;
    // Lifecycle status.
    MarketStatus status;
    // Registration timestamp, seconds.
    uint64 registeredAt;
    // Activation timestamp, seconds.
    uint64 activatedAt;
}
