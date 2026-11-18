// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IssuerProbe} from "./IssuerProbe.sol";

/// @notice Enabled debt reserve of a CDP Spoke.
/// @dev Written by `enableDebtReserve`. `fundingHub` is the home Hub or, through a cross-Hub credit line, another Hub.
struct DebtReserveDef {
    // CDP Spoke reserve identifier.
    uint256 reserveId;
    // Underlying debt asset.
    address asset;
    uint8 decimals;
    // Hub that funds the reserve.
    address fundingHub;
    // Hub asset identifier of the debt asset on the funding Hub.
    uint256 hubAssetId;
    // AaveOracle price source of the reserve.
    address priceSource;
    // True for a fixed-price source; such a source has no age.
    bool fixedPrice;
    // First-Loss Reserve of (fundingHub, asset).
    address firstLossReserve;
    bool approved;
}

/// @notice Implementation immutables of the MarketRegistry and of each of its logic contracts.
/// @dev Every field is non-zero; changing one is an upgrade.
struct MarketRegistryImmutables {
    // The chain's AvanaTimelock, the only holder of `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`.
    address timelock;
    // The Aave governance executor, protected from the address freeze.
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

/// @notice The six immutable logic contracts the MarketRegistry delegatecalls for its write bodies.
/// @dev Each must be built with the same `MarketRegistryImmutables` as the MarketRegistry; the constructor checks this.
struct MarketRegistryLogics {
    // Hubs, integrations, First-Loss Reserves, cross-Hub lines, the flash source, CDP Spokes and debt reserves.
    address hubs;
    // Tokens, price sources and market listing.
    address listing;
    // Market activation, cancellation and offboarding.
    address activation;
    // Swap routes and the AMM integration contract record.
    address routes;
    // Pause state and reason, address freeze and breakers.
    address safety;
    // Wind-down, close, settlement reserve and the credit-line registry.
    address windDown;
}

/// @notice Lifecycle status of a market.
/// @dev Ordinal values are fixed.
enum MarketStatus {
    None,
    Registered,
    Active,
    Offboarding,
    Cancelled,
    // Terminal after wind-down: no account of the market has debt.
    Closed
}

/// @notice Risk tier of a Hub and of the CDP Spokes that draw from it.
/// @dev Ordinal values are fixed.
enum RiskTier {
    None,
    Stable,
    Correlated,
    Volatile
}

/// @notice CDP Spoke record: one standard Aave V4 Spoke per (Hub, AMM integration, risk tier).
/// @dev Written by `deployCdpSpoke`; only `implementation` changes afterwards, on re-approval after an Aave upgrade.
struct SpokeDef {
    // True once deployed and recorded.
    bool approved;
    // Home Hub that the Spoke's vault-token collateral reserves are supplied to.
    address hub;
    // AMM integration whose markets the Spoke lists.
    uint32 integrationId;
    RiskTier riskTier;
    // Approved standard Spoke implementation behind the Spoke proxy.
    address implementation;
    address aaveOracle;
}

/// @notice Listed token definition (pool token or debt asset).
/// @dev An empty alternate route marks a monitoring-only listing (a fixed-price debt asset).
struct TokenDef {
    bool listed;
    uint8 decimals;
    // Approved USD-pegged stablecoin.
    bool isUsdStable;
    // Chainlink aggregator proxies of the primary TOKEN/USD route.
    address[] primaryRoute;
    // Chainlink aggregator proxies of the alternate route.
    address[] alternateRoute;
    // Issuer-action probe the RiskModule runs for this token (`UsdtFeeRateAndPaused` runs both reads).
    IssuerProbe issuerProbe;
    // Peg module (GSM or PSM) of the token that a backup swap route must avoid, or address(0).
    address pegModule;
}

/// @notice Offboarding record of one market: notice start, the liquidation threshold then, and its target.
/// @dev Field layout is fixed for storage compatibility; `unusedLastStepAt` is always 0.
struct WindDownState {
    // `setMarketOffboarding` time, seconds; 0 while not offboarding.
    uint64 offboardedAt;
    // Unused; always 0.
    uint64 unusedLastStepAt;
    // Collateral factor of the reserve's latest dynamic key when offboarding began, bps.
    uint16 startLtBps;
    // Liquidation threshold the Aave DAO sets after the notice, bps (half of `startLtBps`, rounded down).
    uint16 targetLtBps;
}
