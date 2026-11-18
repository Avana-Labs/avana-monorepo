// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketStatus} from "../policy/market-registry/types/MarketRegistryTypes.sol";
import {PositionShape} from "./PositionShape.sol";

/// @notice Stored market definition.
/// @dev Every n-token array in Avana uses the order of `tokens`.
struct Market {
    uint64 chainId;
    // Hub of the market's CDP Spoke.
    address hub;
    address spoke;
    uint32 integrationId;
    // AMM integration (the AMM protocol's LPVault on this chain).
    address integration;
    // Pool address (address(0) for an AMM protocol keyed by identifier).
    address pool;
    // Pool identifier (bytes32(0) for an AMM protocol keyed by address).
    bytes32 poolId;
    PositionShape shape;
    // Pool tokens in pool order.
    address[] tokens;
    uint8[] tokenDecimals;
    address vaultToken;
    // Vault-token decimals, fixed by the integration's unit definition.
    uint8 decimals;
    address lpOracle;
    // Hub asset identifier of the vault token (set at activation).
    uint256 hubAssetId;
    // CDP Spoke reserve identifier of the vault token (set at activation).
    uint256 reserveId;
    MarketStatus status;
    uint64 registeredAt;
    uint64 activatedAt;
}
