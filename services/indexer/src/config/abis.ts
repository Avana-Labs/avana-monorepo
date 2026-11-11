// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// ABIs the indexer decodes with. Avana and Aave ABIs come only from packages/protocol, generated from the release
// build (TEST-149); the standard OpenZeppelin events below are added to each upgradeable or role-managed contract.
// After an upgrade, the release's ABI is the union of every version live since the start block, so each block
// range decodes with the events that version emitted.

import { mergeAbis } from "ponder";
import { parseAbi } from "viem";
import {
  aaveAdapterAbi,
  aaveV4HubAbi,
  aaveV4SpokeAbi,
  avanaTimelockAbi,
  collateralizationAbi,
  coverageSpokeAbi,
  debtOracleAbi,
  flashLiquidatorAbi,
  lpOracleAbi,
  lpVaultAbi,
  lpVaultSwapAbi,
  marketRegistryAbi,
  parameterStoreAbi,
  payoutEscrowAbi,
  proxyManagerAbi,
  riskModuleAbi,
  vaultTokenAbi,
  vaultTokenFactoryAbi,
} from "@avana/protocol/abis";

/** ERC-1967 and AccessControl events; `Upgraded` drives the implementation table and alert M-22. */
export const upgradeAndRoleEvents = parseAbi([
  "event Upgraded(address indexed implementation)",
  "event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)",
  "event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)",
  "event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole)",
]);

export const abis = {
  AaveAdapter: mergeAbis([aaveAdapterAbi, upgradeAndRoleEvents]),
  LPVaultSwap: mergeAbis([lpVaultSwapAbi, upgradeAndRoleEvents]),
  MarketRegistry: mergeAbis([marketRegistryAbi, upgradeAndRoleEvents]),
  ParameterStore: mergeAbis([parameterStoreAbi, upgradeAndRoleEvents]),
  RiskModule: mergeAbis([riskModuleAbi, upgradeAndRoleEvents]),
  LPOracle: mergeAbis([lpOracleAbi, upgradeAndRoleEvents]),
  DebtOracle: mergeAbis([debtOracleAbi, upgradeAndRoleEvents]),
  AvanaTimelock: avanaTimelockAbi,
  ProxyManager: proxyManagerAbi,
  Collateralization: collateralizationAbi,
  LPVault: lpVaultAbi,
  VaultToken: vaultTokenAbi,
  VaultTokenFactory: vaultTokenFactoryAbi,
  PayoutEscrow: payoutEscrowAbi,
  CoverageSpoke: coverageSpokeAbi,
  FlashLiquidator: flashLiquidatorAbi,
  AaveSpoke: mergeAbis([aaveV4SpokeAbi, upgradeAndRoleEvents]),
  AaveHub: mergeAbis([aaveV4HubAbi, upgradeAndRoleEvents]),
} as const;
