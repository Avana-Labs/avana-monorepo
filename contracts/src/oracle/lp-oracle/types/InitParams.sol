// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../../types/OracleConfig.sol";

/// @notice Arguments of `initialize`.
/// @dev `initialize` runs before the listing batch is scheduled (`MKT-019`), when the MarketRegistry does not yet hold
/// the market, so the market's identity comes from these arguments: the tokens and their pool order are
/// `config.tokens[i].token` (the pricing module checks them against the pool's own order), each token's decimals are
/// read from the token, and `market` is the pricing module's market (concentrated liquidity:
/// `abi.encode(pool, tickLower, tickUpper, unitExp)`, `unitExp` the pool's unit exponent `k` of `SPEC-ORC-005`). The MarketRegistry's `listCollateralMarket` later requires the feed's
/// `marketId()` and `integration()` to match, and `checkConfig` then requires the registered market to carry this
/// feed, this integration, these tokens in this order and the vault-token decimals `d` the feed computed.
/// `isUsdStable.length` equals the market's token count; `isUsdStable[i]` is true for every approved USD-pegged stable
/// (every token of a Stable LP Hub market).
/// @custom:spec REQ-ORACLE-010, REQ-ORACLE-058, REQ-ORACLE-097, MKT-019, Q-370, Q-321
struct InitParams {
    // Avana timelock of this chain, granted DEFAULT_ADMIN_ROLE and APPLICATION_ADMIN (upgrades and `setPokeMinGas`);
    // must equal the implementation constant TIMELOCK, else `AdminRoleOnlyTimelock`.
    address timelock;
    // ParameterStore fixed proxy address.
    address parameterStore;
    // MarketRegistry fixed proxy address.
    address marketRegistry;
    // MarketRegistry identifier the market will be registered under.
    uint256 marketId;
    // The market's AMM integration (the AMM protocol's LPVault on this chain), returned by `integration()`.
    address integration;
    // Stable-ceiling flag per token, in pool order.
    bool[] isUsdStable;
    // Fixed text returned by description().
    string description;
    // Initial minimum gas for poke().
    uint32 pokeMinGas;
    // Configuration validated by checkConfig and evaluated for the seed; its routes are the routes to be listed.
    OracleConfig config;
    // The pricing module's market: pool, exact shape and unit exponent, ABI-encoded by the module.
    bytes market;
}
