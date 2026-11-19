// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The chain's governance accounts (2.15 `REQ-ACCESS-027`, 1.4 role table).
struct GovernanceInputs {
    // Governance Safe (4-of-7): admin of Avana's AccessManager, holder of the governance and tighten roles.
    address governanceSafe;
    // Emergency Guardian (3-of-5).
    address emergencyGuardian;
    // Aave Protocol Guardian.
    address aaveProtocolGuardian;
    // Aave governance executor of the chain.
    address aaveGovernanceExecutor;
    // Joint Configuration Safe (2-of-3): the risk steward, holds the tighten role with no delay.
    address jointConfigSafe;
}

/// @notice One AMM integration: one LPVault and the core stack built on it (1.2 deployment step 6).
struct IntegrationInput {
    uint32 integrationId;
    // "uniswap-v3", "slipstream" or "uniswap-v4".
    string kind;
    // Uniswap v3: one position manager and factory; Slipstream: the four generations of 2.21, index 0 to 3; Uniswap v4:
    // the PositionManager (its factories entry is not read).
    address[] positionManagers;
    address[] factories;
}

/// @notice One operator flash liquidation helper per keeper instance (`REQ-HELPER-011`).
struct OperatorHelperInput {
    address signer;
    address fundingSafe;
    uint256 maxTopUpBps;
}

/// @notice The RiskModule settings the listing-setup operation sets on every stack.
struct CoreParams {
    // Avana's share of the realized liquidation surplus, bps (at most `RiskModule.MAX_FEE_SHARE_BPS`).
    uint16 feeShareBps;
    address feeRecipient;
    // First-Loss coverage of the summed draw caps, bps.
    uint16 coverageRatioBps;
    // The governance delay source, seconds: the governance role's execution delay when it lies between 4 and 5 days,
    // else 4 days (`AvanaAccess.governanceDelay`).
    uint256 timelockNormalDelay;
}

/// @notice Everything `03_DeployAvana` needs for one chain; read from `script/deploy/config/<network>.json`.
struct ChainInputs {
    string network;
    uint256 chainId;
    // Release tag vX.Y.Z; part of every salt.
    string release;
    GovernanceInputs gov;
    // The chain's Aave V3 Pool: lender of FlashloanRepay and of the operator flash liquidators; zero skips both.
    address v3Pool;
    CoreParams params;
    address[] keepers;
    OperatorHelperInput[] operatorHelpers;
    IntegrationInput[] integrations;
}

/// @notice The core stack of one integration: the RiskModule's `LP_VAULT` is immutable, so each LPVault has its own.
struct CoreStack {
    uint32 integrationId;
    string kind;
    address lpVault;
    address riskModule;
    address liquidationModule;
    address aaveAdapter;
    // Zero without an Aave V3 Pool.
    address flashloanRepay;
    // One per operator helper; empty without an Aave V3 Pool.
    address[] flashLiquidators;
}

/// @notice Every address `03_DeployAvana` deploys.
struct AvanaDeployment {
    address factory;
    address deployer;
    address accessManager;
    CoreStack[] stacks;
}
