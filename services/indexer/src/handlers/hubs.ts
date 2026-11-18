// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Hubs and their Spokes: MarketRegistry `HubRecorded` and `SpokeApproved`, and Aave Hub `AddSpoke`.
// Each upsert writes the event's values, so a second delivery of a log (aaveSources.ts) leaves the row as it is.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { AAVE_HUB_SOURCES } from "../config/aaveSources.ts";
import { recordLog } from "../lib/record.ts";

ponder.on("MarketRegistry:HubRecorded", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.HubRecorded");
  await context.db
    .insert(schema.hub)
    .values({ chainId: p.chainId, hub: event.args.hub, tier: Number(event.args.tier), recordedBlock: p.blockNumber, lastBlock: p.blockNumber })
    .onConflictDoUpdate({ tier: Number(event.args.tier), lastBlock: p.blockNumber });
});

ponder.on("MarketRegistry:SpokeApproved", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.SpokeApproved");
  const a = event.args;
  const row = { hub: a.hub, integrationId: Number(a.integrationId), implementation: a.implementation, aaveOracle: a.aaveOracle, lastBlock: p.blockNumber };
  await context.db
    .insert(schema.cdpSpoke)
    .values({ chainId: p.chainId, spoke: a.spoke, ...row })
    .onConflictDoUpdate(row);
});

for (const source of AAVE_HUB_SOURCES) {
  ponder.on(`${source}:AddSpoke`, async ({ event, context }) => {
    const p = await recordLog(event, context, "AaveHub.AddSpoke");
    await context.db
      .insert(schema.hubSpoke)
      .values({ chainId: p.chainId, hub: event.log.address, assetId: event.args.assetId, spoke: event.args.spoke, addedBlock: p.blockNumber })
      .onConflictDoNothing();
  });
}
