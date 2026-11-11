// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Implementation immutables of the MarketRegistry and of each of its logic contracts, all per chain.
/// @dev One struct keeps the constructors within the EVM stack. Every field is non-zero; a change is an upgrade to an
/// implementation built with new values, at the normal delay (REQ-CONFIG-005).
/// @custom:spec REQ-CONFIG-005, REQ-MREG-020, Q-226, Q-313
struct MarketRegistryImmutables {
    // The chain's AvanaTimelock, the only holder of `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`.
    address timelock;
    // The Aave governance executor: the only caller of `cancelStandbySwitch`.
    address aaveGovernanceExecutor;
    // The VaultTokenFactory.
    address vaultTokenFactory;
    // The AaveAdapter fixed proxy.
    address aaveAdapter;
    // Collateralization.
    address collateralization;
    // The Lock.
    address lock;
    // The ProxyManager.
    address proxyManager;
    // The ParameterStore fixed proxy.
    address parameterStore;
    // The RiskModule fixed proxy.
    address riskModule;
    // The LPVaultSwap fixed proxy.
    address lpVaultSwap;
    // The PayoutEscrow.
    address payoutEscrow;
    // The public flash liquidation helper (2.11 REQ-HELPER-010), protected from the address freeze. Its constructor
    // reads this registry, so it is deployed after the registry at the address the deployment manifest fixes in advance.
    address flashLiquidator;
    // The audited standard Aave V4 Spoke implementation whose code hash every CDP Spoke's implementation must match.
    address standardSpokeImplementation;
}
