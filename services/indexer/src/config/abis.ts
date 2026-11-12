// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// ABIs the indexer decodes with. Avana and Aave ABIs come only from packages/protocol, generated from the release
// build (TEST-149); the standard OpenZeppelin events below are added to each upgradeable or role-managed contract.
// After an upgrade, the release's ABI is the union of every version live since the start block, so each block
// range decodes with the events that version emitted.

import { mergeAbis } from "ponder";
import { getAbiItem, parseAbi } from "viem";
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

/**
 * Events that announce contracts created after deployment; sources.ts follows each child address through them. They are
 * taken from the generated ABIs rather than written by hand, so a changed event signature (a different topic0) is a
 * type error here instead of a factory source that silently matches no log.
 */
export const factoryEvents = {
  /** VaultTokenFactory: a market's vault token; child address in `vaultToken`. */
  vaultTokenDeployed: getAbiItem({ abi: vaultTokenFactoryAbi, name: "VaultTokenDeployed" }),
  /** MarketRegistry: a listed market and its LPOracle; child address in `lpOracle`. */
  marketRegistered: getAbiItem({ abi: marketRegistryAbi, name: "MarketRegistered" }),
  /** MarketRegistry: an approved debt reserve and its DebtOracle; child address in `priceSource`. */
  debtReserveApproved: getAbiItem({ abi: marketRegistryAbi, name: "DebtReserveApproved" }),
  /** MarketRegistry: the Coverage Spoke of a Hub asset; child address in `coverageSpoke`. */
  coverageSpokeSet: getAbiItem({ abi: marketRegistryAbi, name: "CoverageSpokeSet" }),
  /** MarketRegistry: a recorded Hub; child address in `hub`. */
  hubRecorded: getAbiItem({ abi: marketRegistryAbi, name: "HubRecorded" }),
  /** MarketRegistry: an approved CDP Spoke; child address in `spoke`. */
  spokeApproved: getAbiItem({ abi: marketRegistryAbi, name: "SpokeApproved" }),
  /** Aave V4 Hub: a Spoke added to one of its assets; child address in `spoke`. */
  addSpoke: getAbiItem({ abi: aaveV4HubAbi, name: "AddSpoke" }),
} as const;
