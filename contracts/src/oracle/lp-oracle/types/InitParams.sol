// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../../types/OracleConfig.sol";

/// @notice Arguments of `initialize`.
/// @dev The MarketRegistry does not yet hold the market, so its identity comes from these arguments.
struct InitParams {
    // Avana timelock; must equal the implementation's TIMELOCK.
    address timelock;
    address parameterStore;
    address marketRegistry;
    // MarketRegistry identifier the market will be registered under.
    uint256 marketId;
    // The market's AMM integration (LPVault).
    address integration;
    // Stable-ceiling flag per token, in pool order.
    bool[] isUsdStable;
    string description;
    uint32 pokeMinGas;
    // Configuration validated by checkConfig and evaluated for the seed.
    OracleConfig config;
    // The pricing module's market encoding (pool, range and unit exponent).
    bytes market;
}
