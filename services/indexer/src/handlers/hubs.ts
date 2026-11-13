// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Hubs, their Spokes and the credit lines between them: MarketRegistry `HubRecorded`, `SpokeApproved`,
// `CrossHubLineSet`, `CrossHubLinesEnabledSet`, `CreditLineSet` and `CreditLineRecorded`, and Aave Hub `AddSpoke`.
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

ponder.on("MarketRegistry:CrossHubLineSet", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.CrossHubLineSet");
  const a = event.args;
  const row = { cap: a.cap, total: a.total, lastBlock: p.blockNumber };
  await context.db
    .insert(schema.crossHubLine)
    .values({ chainId: p.chainId, fundingHub: a.fundingHub, asset: a.asset, spoke: a.spoke, ...row })
    .onConflictDoUpdate(row);
});

ponder.on("MarketRegistry:CrossHubLinesEnabledSet", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.CrossHubLinesEnabledSet");
  const row = { enabled: event.args.enabled, lastBlock: p.blockNumber };
  await context.db
    .insert(schema.crossHubConfig)
    .values({ chainId: p.chainId, ...row })
    .onConflictDoUpdate(row);
});

ponder.on("MarketRegistry:CreditLineSet", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.CreditLineSet");
  const a = event.args;
  const row = { line: a.line, sum: a.sum, lastBlock: p.blockNumber };
  await context.db
    .insert(schema.creditLine)
    .values({ chainId: p.chainId, hub: a.hub, asset: a.asset, ...row })
    .onConflictDoUpdate(row);
});

ponder.on("MarketRegistry:CreditLineRecorded", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.CreditLineRecorded");
  const a = event.args;
  await context.db
    .insert(schema.creditLineSpoke)
    .values({ chainId: p.chainId, hub: a.hub, asset: a.asset, spoke: a.spoke, drawCap: a.drawCap, lastBlock: p.blockNumber })
    .onConflictDoUpdate({ drawCap: a.drawCap, lastBlock: p.blockNumber });
  // The line's running sum moves with every recorded draw cap; the line itself is set by CreditLineSet.
  await context.db
    .insert(schema.creditLine)
    .values({ chainId: p.chainId, hub: a.hub, asset: a.asset, line: 0n, sum: a.sum, lastBlock: p.blockNumber })
    .onConflictDoUpdate({ sum: a.sum, lastBlock: p.blockNumber });
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
