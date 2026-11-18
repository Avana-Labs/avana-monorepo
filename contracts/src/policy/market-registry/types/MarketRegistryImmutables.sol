// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Implementation immutables of the MarketRegistry and of each of its logic contracts.
/// @dev Every field is non-zero; changing one is an upgrade.
struct MarketRegistryImmutables {
    // The chain's AvanaTimelock, the only holder of `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`.
    address timelock;
    // The Aave governance executor: the only caller of `cancelStandbySwitch`.
    address aaveGovernanceExecutor;
    address vaultTokenFactory;
    // The AaveAdapter fixed proxy.
    address aaveAdapter;
    address collateralization;
    address lock;
    address proxyManager;
    // The ParameterStore fixed proxy.
    address parameterStore;
    // The RiskModule fixed proxy.
    address riskModule;
    // The LPVaultSwap fixed proxy.
    address lpVaultSwap;
    address payoutEscrow;
    // The public flash liquidation helper, protected from the address freeze.
    address flashLiquidator;
    // The standard Aave V4 Spoke implementation, approved from deployment.
    address standardSpokeImplementation;
    // The most markets the registry ever lists; bounds the ParameterStore re-check walk over market IDs.
    uint256 maxMarketCount;
}
