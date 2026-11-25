// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Aave Hub and Spoke upgrades, the Avana AccessManager's role and operation events, and the loss layers: each
// First-Loss Reserve's and DAO deficit offset's funded balance and every deficit it covered.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { AAVE_HUB_SOURCES, AAVE_SPOKE_SOURCES, FIRST_LOSS_SOURCES } from "../config/aaveSources.ts";
import { logOnly } from "../lib/logOnly.ts";
import { recordLog } from "../lib/record.ts";

const UPGRADEABLE = [...AAVE_SPOKE_SOURCES.map((c) => [c, "AaveSpoke"] as const), ...AAVE_HUB_SOURCES.map((c) => [c, "AaveHub"] as const)];

for (const [contract, kind] of UPGRADEABLE) {
  ponder.on(`${contract}:Upgraded`, async ({ event, context }) => {
    const p = await recordLog(event, context, `${kind}.Upgraded`);
    const row = { implementation: event.args.implementation, changedBlock: p.blockNumber };
    await context.db
      .insert(schema.implementation)
      .values({ chainId: p.chainId, proxy: event.log.address, ...row })
      .onConflictDoUpdate(row);
  });
}

logOnly("AccessManager", [
  "RoleGranted",
  "RoleRevoked",
  "RoleLabel",
  "RoleAdminChanged",
  "RoleGuardianChanged",
  "RoleGrantDelayChanged",
  "TargetFunctionRoleUpdated",
  "TargetAdminDelayUpdated",
  "TargetClosed",
  "OperationScheduled",
  "OperationExecuted",
  "OperationCanceled",
]);

for (const source of FIRST_LOSS_SOURCES) {
  for (const name of ["Funded", "DeficitCovered", "Withdrawn"] as const) {
    ponder.on(`${source}:${name}`, async ({ event, context }) => {
      const p = await recordLog(event, context, `FirstLossReserve.${name}`);
      if (!p.fresh) return;
      const row = { balance: event.args.balanceAfter, lastBlock: p.blockNumber };
      await context.db
        .insert(schema.coverageBalance)
        .values({ chainId: p.chainId, firstLossReserve: event.log.address, ...row })
        .onConflictDoUpdate(row);
      if (name !== "DeficitCovered") return;
      const a = event.args as { spoke: `0x${string}`; caller: `0x${string}`; covered: bigint; shares: bigint; balanceAfter: bigint };
      await context.db
        .insert(schema.firstLossCover)
        .values({
          chainId: p.chainId,
          txHash: p.txHash,
          logIndex: p.logIndex,
          blockNumber: p.blockNumber,
          firstLossReserve: event.log.address,
          spoke: a.spoke,
          caller: a.caller,
          covered: a.covered,
          shares: a.shares,
          balanceAfter: a.balanceAfter,
        })
        .onConflictDoNothing();
    });
  }
  logOnly(source, ["SpokeAllowed", "MinimumSet", "BelowMinimum"], "FirstLossReserve");
}
