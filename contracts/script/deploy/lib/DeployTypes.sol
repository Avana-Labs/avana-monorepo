// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Chain-wide parameters of the old ParameterStore, kept for the deploy inputs until the deploy scripts are
/// rebuilt for the core contracts.
struct GlobalParams {
    // Most flash premium the flash source may charge, bps of the amount lent.
    uint16 maxFlashFeeBps;
    // Avana share of realized liquidation surplus, bps.
    uint16 avanaFeeShareBps;
    address feeRecipient;
    // Largest per-leg slippage raise a caller shortfall top-up can buy, bps.
    uint16 maxShortfallBps;
}

/// @notice The chain's governance accounts (2.15 `REQ-ACCESS-027`, 1.4 role table).
struct GovernanceInputs {
    // Governance Safe (4-of-7): proposer, executor, canceller.
    address governanceSafe;
    // Emergency Guardian (3-of-5): canceller, MarketRegistry and ParameterStore guardian.
    address emergencyGuardian;
    // Aave Protocol Guardian: canceller, MarketRegistry and ParameterStore guardian.
    address aaveProtocolGuardian;
    // Aave governance executor of the chain: proposer, canceller, DAO canceller, `AAVE_GOVERNANCE_EXECUTOR`.
    address aaveGovernanceExecutor;
    // Joint Configuration Safe (2-of-3): MarketRegistry guardian, ParameterStore risk steward.
    address jointConfigSafe;
}

/// @notice One Aave V4 Hub Avana records, with its risk tier (`MarketRegistry.recordHub`).
struct HubInput {
    address hub;
    // RiskTier: 1 Stable, 2 Correlated, 3 Volatile.
    uint8 tier;
}

/// @notice The Aave contracts Avana's deployment reads or names.
struct AaveInputs {
    // The Aave V4 AccessManager (authority of every First-Loss Reserve).
    address accessManager;
    // The audited standard Spoke implementation every CDP Spoke must match (`MarketRegistryImmutables`).
    address standardSpokeImplementation;
    // The chain's Aave V3 Pool: lender of the flash source and of the flash liquidation helpers.
    address v3Pool;
    // The Avana Hubs (Stable LP, Correlated LP, Volatile LP) recorded by the wiring operation.
    HubInput[] hubs;
}

/// @notice One AMM integration's LPVault (1.2 deployment step 6).
struct IntegrationInput {
    uint32 integrationId;
    // "uniswap-v3", "slipstream" or "uniswap-v4".
    string kind;
    // Uniswap v3: one position manager and factory; Slipstream: the four generations of 2.21, index 0 to 3; Uniswap v4:
    // the PositionManager and the chain's Uniswap v3 factory, whose pools are the reference pools.
    address[] positionManagers;
    address[] factories;
}

/// @notice One operator flash liquidation helper per keeper instance (`REQ-HELPER-011`).
struct OperatorHelperInput {
    address signer;
    address fundingSafe;
    uint256 maxTopUpBps;
}

/// @notice Everything `03_DeployAvana` needs for one chain; read from `script/deploy/config/<network>.json`.
struct ChainInputs {
    string network;
    uint256 chainId;
    // Release tag vX.Y.Z; part of every salt.
    string release;
    GovernanceInputs gov;
    AaveInputs aave;
    // Seconds per block (12 on Ethereum and Sepolia, 2 on Base).
    uint32 blockTime;
    GlobalParams globals;
    uint256 maxMarketCount;
    uint256 keeperFloor;
    // The governance delay source, seconds (432,000): the governance role's execution delay when it lies between
    // 4 and 5 days, else 4 days (`AvanaAccess.governanceDelay`).
    uint256 timelockNormalDelay;
    address[] keepers;
    OperatorHelperInput[] operatorHelpers;
    IntegrationInput[] integrations;
}

/// @notice One upgradeable contract: its fixed proxy, its implementation and the logic contracts it forwards to.
struct UpgradeableDeployment {
    address proxy;
    address implementation;
    address[] logics;
}

/// @notice Every address `03_DeployAvana` deploys.
struct AvanaDeployment {
    address factory;
    address deployer;
    address accessManager;
    UpgradeableDeployment marketRegistry;
    UpgradeableDeployment parameterStore;
    UpgradeableDeployment riskModule;
    UpgradeableDeployment aaveAdapter;
    UpgradeableDeployment lpVaultSwap;
    address lock;
    address collateralization;
    address vaultTokenFactory;
    address proxyManager;
    address payoutEscrow;
    address flashSource;
    address flashLiquidator;
    address[] lpVaults;
}
