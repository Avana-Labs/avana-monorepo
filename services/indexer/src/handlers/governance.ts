// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Implementations and roles of every upgradeable contract, ParameterStore and RiskModule
// events, First-Loss Reserve balances, vault tokens and the factory.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { AAVE_HUB_SOURCES, AAVE_SPOKE_SOURCES, FIRST_LOSS_SOURCES } from "../config/aaveSources.ts";
import { logOnly } from "../lib/logOnly.ts";
import { recordLog } from "../lib/record.ts";

/**
 * Contracts whose ABI carries ERC-1967 `Upgraded` and AccessControl role events (src/config/abis.ts), each with the
 * kind its logs are recorded under: every Aave Hub or Spoke source records under the Aave contract's name.
 */
const UPGRADEABLE = [
  ...(["AaveAdapter", "LPVaultSwap", "MarketRegistry", "ParameterStore", "RiskModule"] as const).map((c) => [c, c] as const),
  ...AAVE_SPOKE_SOURCES.map((c) => [c, "AaveSpoke"] as const),
  ...AAVE_HUB_SOURCES.map((c) => [c, "AaveHub"] as const),
];

for (const [contract, kind] of UPGRADEABLE) {
  ponder.on(`${contract}:Upgraded`, async ({ event, context }) => {
    const p = await recordLog(event, context, `${kind}.Upgraded`);
    const row = { implementation: event.args.implementation, changedBlock: p.blockNumber };
    await context.db
      .insert(schema.implementation)
      .values({ chainId: p.chainId, proxy: event.log.address, ...row })
      .onConflictDoUpdate(row);
  });
  for (const [name, granted] of [["RoleGranted", true], ["RoleRevoked", false]] as const) {
    ponder.on(`${contract}:${name}`, async ({ event, context }) => {
      const p = await recordLog(event, context, `${kind}.${name}`);
      await context.db
        .insert(schema.roleMember)
        .values({ chainId: p.chainId, contract: event.log.address, role: event.args.role, account: event.args.account, granted, lastBlock: p.blockNumber })
        .onConflictDoUpdate({ granted, lastBlock: p.blockNumber });
    });
  }
  // A role's admin role changing moves who can grant it (M-22); kept in the log under the contract's kind.
  ponder.on(`${contract}:RoleAdminChanged`, async ({ event, context }) => {
    await recordLog(event, context, `${kind}.RoleAdminChanged`);
  });
}

logOnly("ParameterStore", [
  "AuthorityUpdated",
  "MarketDynamicCapSet",
  "ParameterTightened",
  "ParameterLoosened",
  "ParameterSet",
  "CapTightened",
  "CapLoosened",
  "StressFloorSet",
  "FeedConfigured",
  "RouteDepthThresholdSet",
  "MinPledgeUsdSet",
  "DebtAssetParamsSet",
]);

logOnly("RiskModule", ["AuthorityUpdated", "ConfigDriftDetected"]);

for (const source of FIRST_LOSS_SOURCES) {
  for (const name of ["ReserveFunded", "DeficitCovered", "ReserveWithdrawn"] as const) {
    ponder.on(`${source}:${name}`, async ({ event, context }) => {
      const p = await recordLog(event, context, `AvanaFirstLossReserve.${name}`);
      if (!p.fresh) return;
      const row = { balance: event.args.balanceAfter, lastBlock: p.blockNumber };
      await context.db
        .insert(schema.coverageBalance)
        .values({ chainId: p.chainId, firstLossReserve: event.log.address, ...row })
        .onConflictDoUpdate(row);
    });
  }
  logOnly(source, ["AuthorityUpdated", "ReserveBelowMinimum", "BorrowSpokeAllowlistUpdated", "FirstLossReserveMinimumUpdated"], "AvanaFirstLossReserve");
}

logOnly("VaultToken", ["Transfer", "ProxyAdded"]);
logOnly("VaultTokenFactory", ["IntegrationRegistered", "VaultTokenDeployed"]);
