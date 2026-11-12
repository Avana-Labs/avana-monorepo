// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {GlobalParams} from "../../../src/policy/parameter-store/types/GlobalParams.sol";

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
    // The Aave V4 AccessManager (authority of every Coverage Spoke).
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
    // "uniswap-v3" or "slipstream".
    string kind;
    // Uniswap v3: one position manager and factory; Slipstream: the four generations of 2.21, index 0 to 3.
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
    bool hasSequencer;
    address sequencerFeed;
    uint32 sequencerGraceSeconds;
    GlobalParams globals;
    uint16 initialPoolShareMaxBps;
    uint256 maxMarketCount;
    uint256 keeperFloor;
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
    address timelock;
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
    address[] operatorHelpers;
    address[] lpVaults;
    address lens;
    address[] lensModules;
    address lensAaveSizing;
    address debtOracleImplementation;
    // The concentrated-liquidity LPOracle implementation each integration registers as its pricing; zero while that
    // contract is not in the build (03_DeployAvana reports it and the wiring operation leaves the integration out).
    address clOraclePricing;
}
