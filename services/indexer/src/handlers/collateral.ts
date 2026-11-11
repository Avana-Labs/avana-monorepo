// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Collateralization records, pending seized units and LPVault custody.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { logOnly } from "../lib/logOnly.ts";
import { recordLog } from "../lib/record.ts";

ponder.on("Collateralization:CollateralPledged", async ({ event, context }) => {
  const p = await recordLog(event, context, "Collateralization.CollateralPledged");
  const a = event.args;
  await context.db.insert(schema.collateralRecord).values({
    chainId: p.chainId,
    collateralization: event.log.address,
    recordId: a.recordId,
    integrationId: Number(a.integrationId),
    positionKey: a.positionKey,
    depositor: a.depositor,
    proxy: a.proxy,
    vaultToken: a.vaultToken,
    credited: a.credited,
    rescueUnits: 0n,
    open: true,
    lastBlock: p.blockNumber,
    lastBlockHash: p.blockHash,
    lastLogIndex: p.logIndex,
  });
});

/** Record events always follow the record's CollateralPledged; a missing record stops the indexer (fail closed). */
function recordUpdate(kind: string, change: (args: any, row: typeof schema.collateralRecord.$inferSelect) => Partial<typeof schema.collateralRecord.$inferInsert>) {
  ponder.on(`Collateralization:${kind}` as Parameters<typeof ponder.on>[0], async ({ event, context }: any) => {
    const p = await recordLog(event, context, `Collateralization.${kind}`);
    const key = { chainId: p.chainId, collateralization: event.log.address, recordId: event.args.recordId as bigint };
    await context.db
      .update(schema.collateralRecord, key)
      .set((row: typeof schema.collateralRecord.$inferSelect) => ({
        ...change(event.args, row),
        lastBlock: p.blockNumber,
        lastBlockHash: p.blockHash,
        lastLogIndex: p.logIndex,
      }));
  });
}

recordUpdate("CollateralReleased", () => ({ open: false, credited: 0n }));
recordUpdate("RecordDebited", (a) => ({ credited: a.creditedAfter as bigint, open: (a.creditedAfter as bigint) > 0n }));
recordUpdate("RecordReduced", (a, row) => ({ credited: row.credited - (a.units as bigint) }));
recordUpdate("RecordRecredited", (a, row) => ({
  credited: row.credited + (a.added as bigint),
  rescueUnits: row.rescueUnits + (a.rescueUnits as bigint),
}));

ponder.on("Collateralization:SeizureReconciled", async ({ event, context }) => {
  const p = await recordLog(event, context, "Collateralization.SeizureReconciled");
  await context.db
    .insert(schema.pendingSettlement)
    .values({ chainId: p.chainId, vaultToken: event.args.vaultToken, units: event.args.units, lastBlock: p.blockNumber })
    .onConflictDoUpdate((row) => ({ units: row.units + event.args.units, lastBlock: p.blockNumber }));
});

ponder.on("Collateralization:PendingSettled", async ({ event, context }) => {
  const p = await recordLog(event, context, "Collateralization.PendingSettled");
  await context.db
    .update(schema.pendingSettlement, { chainId: p.chainId, vaultToken: event.args.vaultToken })
    .set((row) => ({ units: row.units - event.args.units, lastBlock: p.blockNumber }));
});

logOnly("Collateralization", ["SeizureSettled", "CounterSaturated"]);

ponder.on("LPVault:PositionReceived", async ({ event, context }) => {
  const p = await recordLog(event, context, "LPVault.PositionReceived");
  const a = event.args;
  await context.db
    .insert(schema.lpPosition)
    .values({ chainId: p.chainId, lpVault: event.log.address, positionKey: a.positionKey, marketId: a.marketId, depositor: a.depositor, held: true, stray: false, lastBlock: p.blockNumber })
    .onConflictDoUpdate({ marketId: a.marketId, depositor: a.depositor, held: true, stray: false, lastBlock: p.blockNumber });
});

ponder.on("LPVault:PositionReturned", async ({ event, context }) => {
  const p = await recordLog(event, context, "LPVault.PositionReturned");
  await context.db
    .update(schema.lpPosition, { chainId: p.chainId, lpVault: event.log.address, positionKey: event.args.positionKey })
    .set({ held: false, lastBlock: p.blockNumber });
});

ponder.on("LPVault:StrayReceived", async ({ event, context }) => {
  const p = await recordLog(event, context, "LPVault.StrayReceived");
  await context.db
    .insert(schema.lpPosition)
    .values({ chainId: p.chainId, lpVault: event.log.address, positionKey: event.args.positionKey, marketId: 0n, depositor: event.args.from, held: true, stray: true, lastBlock: p.blockNumber })
    .onConflictDoUpdate({ held: true, stray: true, lastBlock: p.blockNumber });
});

ponder.on("LPVault:StrayReturned", async ({ event, context }) => {
  const p = await recordLog(event, context, "LPVault.StrayReturned");
  await context.db
    .update(schema.lpPosition, { chainId: p.chainId, lpVault: event.log.address, positionKey: event.args.positionKey })
    .set({ held: false, lastBlock: p.blockNumber });
});

logOnly("LPVault", ["MarketBound", "UnitsUnwound", "UnitsReleased", "FeesCollected"]);
