// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// ABIs the indexer decodes with. Avana and Aave ABIs come only from packages/protocol, generated from the release
// build (TEST-149). The core contracts are not upgradeable; the ERC-1967 `Upgraded` event is added to the Aave Hubs
// and Spokes, which are.

import { mergeAbis } from "ponder";
import { getAbiItem, parseAbi } from "viem";
import {
  aaveAdapterAbi,
  aaveV4HubAbi,
  aaveV4SpokeAbi,
  accessManagerAbi,
  firstLossReserveAbi,
  flashLiquidatorAbi,
  flashloanRepayAbi,
  liquidationModuleAbi,
  lpVaultAbi,
  riskModuleAbi,
  vaultTokenAbi,
} from "@avana/protocol/abis";

/** ERC-1967 `Upgraded`; drives the implementation table and the monitor's upgrade alert. */
export const upgradeEvents = parseAbi(["event Upgraded(address indexed implementation)"]);

export const abis = {
  AaveAdapter: aaveAdapterAbi,
  RiskModule: riskModuleAbi,
  LiquidationModule: liquidationModuleAbi,
  FlashloanRepay: flashloanRepayAbi,
  FlashLiquidator: flashLiquidatorAbi,
  LPVault: lpVaultAbi,
  VaultToken: vaultTokenAbi,
  FirstLossReserve: firstLossReserveAbi,
  AccessManager: accessManagerAbi,
  AaveSpoke: mergeAbis([aaveV4SpokeAbi, upgradeEvents]),
  AaveHub: mergeAbis([aaveV4HubAbi, upgradeEvents]),
} as const;

/**
 * Events that announce contracts created after deployment; sources.ts follows each child address through them. They are
 * taken from the generated ABIs rather than written by hand, so a changed event signature (a different topic0) is a
 * type error here instead of a factory source that silently matches no log.
 */
export const factoryEvents = {
  /** RiskModule: an activated market; child address in `vaultToken`. */
  marketActivated: getAbiItem({ abi: riskModuleAbi, name: "MarketActivated" }),
  /** RiskModule: a debt reserve with its First-Loss Reserve; child address in `firstLossReserve`. */
  debtReserveSet: getAbiItem({ abi: riskModuleAbi, name: "DebtReserveSet" }),
  /** Aave V4 Hub: a Spoke added to one of its assets; child address in `spoke`. */
  addSpoke: getAbiItem({ abi: aaveV4HubAbi, name: "AddSpoke" }),
} as const;
