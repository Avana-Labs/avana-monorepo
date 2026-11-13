// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The chain's fixed dependencies of the AaveAdapter implementation and of each of its logic contracts.
/// @dev Every field is non-zero; the router and every logic contract are built with the same values, which the router
/// checks through `logicConfig()`.
/// @custom:spec REQ-ADAPTER-004, REQ-ADAPTER-074
struct AaveAdapterImmutables {
    // The chain's ProxyManager.
    address proxyManager;
    // Collateralization.
    address collateralization;
    // The RiskModule.
    address riskModule;
    // The MarketRegistry.
    address marketRegistry;
    // The ParameterStore (the sequencer feed of a repay with collateral).
    address parameterStore;
    // LPVaultSwap.
    address lpVaultSwap;
    // The protocol Lock.
    address lock;
    // The VaultTokenFactory.
    address vaultTokenFactory;
    // The AvanaTimelock, the only holder of the admin roles.
    address timelock;
}
