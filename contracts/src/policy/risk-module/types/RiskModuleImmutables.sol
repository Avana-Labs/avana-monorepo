// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Implementation immutables of the RiskModule and of each of its logic contracts, all per chain.
/// @dev One struct keeps the constructors within the EVM stack. Every field is non-zero; a change is an upgrade to an
/// implementation built with new values, at the normal delay (REQ-RISK-002). There is no Hub, AMM-protocol or debt-asset
/// field: every market's Hub, Spoke, integration and tokens come from the MarketRegistry (Q-313).
/// @custom:spec REQ-RISK-002, REQ-RISK-055, Q-226, Q-313
struct RiskModuleImmutables {
    // The chain's MarketRegistry fixed proxy.
    address marketRegistry;
    // The chain's ParameterStore fixed proxy.
    address parameterStore;
    // Collateralization, the caller of `checkPledge`.
    address collateralization;
    // The AaveAdapter fixed proxy, the caller of the borrow-side checks.
    address adapter;
    // LPVaultSwap fixed proxy, read for `activeKeeperCount`.
    address lpVaultSwap;
    // The chain's AvanaTimelock, the only holder of `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`.
    address timelock;
}
