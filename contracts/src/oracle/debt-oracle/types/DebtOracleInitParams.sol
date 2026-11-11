// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Arguments of `IDebtOracle.initialize`.
/// @dev `asset`, `marketRegistry` and `parameterStore` are fixed for the life of the proxy and returned by `ASSET()`,
/// `MARKET_REGISTRY()` and `PARAMETER_STORE()`, which `MarketRegistry.approveDebtReserve` checks.
/// @custom:spec REQ-ORACLE-091, REQ-ORACLE-097
struct DebtOracleInitParams {
    // Avana timelock, granted DEFAULT_ADMIN_ROLE and APPLICATION_ADMIN (upgrades and `setPokeMinGas`); must equal the
    // implementation constant TIMELOCK, else `AdminRoleOnlyTimelock`.
    address timelock;
    // The debt asset this feed prices; a listed MarketRegistry token without a fixed Aave source.
    address asset;
    // MarketRegistry fixed proxy address.
    address marketRegistry;
    // ParameterStore fixed proxy address.
    address parameterStore;
    // Fixed text returned by description().
    string description;
    // Initial minimum gas for poke() and after every caught failure.
    uint32 pokeMinGas;
}
