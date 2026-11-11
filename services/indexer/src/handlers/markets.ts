// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// MarketRegistry listing, debt reserves, pause state, address freezes and breakers.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { PAUSE_REASON, PAUSE_STATE, enumName, logOnly } from "../lib/logOnly.ts";
import { recordLog } from "../lib/record.ts";

ponder.on("MarketRegistry:MarketRegistered", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.MarketRegistered");
  const a = event.args;
  await context.db.insert(schema.market).values({
    chainId: p.chainId,
    marketId: a.marketId,
    integrationId: Number(a.integrationId),
    spoke: a.spoke,
    pool: a.pool,
    poolId: a.poolId,
    tokens: a.tokens.map((t) => t.toLowerCase()),
    vaultToken: a.vaultToken,
    lpOracle: a.lpOracle,
    status: "Registered",
    lastBlock: p.blockNumber,
  });
});

ponder.on("MarketRegistry:MarketActivated", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.MarketActivated");
  const a = event.args;
  await context.db
    .update(schema.market, { chainId: p.chainId, marketId: a.marketId })
    .set({ status: "Active", reserveId: a.reserveId, hub: a.hub, hubAssetId: a.hubAssetId, lastBlock: p.blockNumber });
});

for (const [name, status] of [
  ["MarketRegistrationCancelled", "Cancelled"],
  ["MarketOffboarding", "Offboarding"],
  ["MarketClosed", "Closed"],
] as const) {
  ponder.on(`MarketRegistry:${name}`, async ({ event, context }) => {
    const p = await recordLog(event, context, `MarketRegistry.${name}`);
    await context.db.update(schema.market, { chainId: p.chainId, marketId: event.args.marketId }).set({ status, lastBlock: p.blockNumber });
  });
}

ponder.on("MarketRegistry:SettlementReserveSet", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.SettlementReserveSet");
  await context.db
    .update(schema.market, { chainId: p.chainId, marketId: event.args.marketId })
    .set({ settlementReserveId: event.args.debtReserveId, lastBlock: p.blockNumber });
});

ponder.on("MarketRegistry:DebtReserveApproved", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.DebtReserveApproved");
  const a = event.args;
  const row = {
    asset: a.asset,
    fundingHub: a.fundingHub,
    hubAssetId: a.hubAssetId,
    priceSource: a.priceSource,
    coverageSpoke: a.coverageSpoke,
    approved: true,
    lastBlock: p.blockNumber,
  };
  await context.db
    .insert(schema.debtReserve)
    .values({ chainId: p.chainId, spoke: a.spoke, debtReserveId: a.reserveId, ...row })
    .onConflictDoUpdate(row);
});

ponder.on("MarketRegistry:DebtReserveRemoved", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.DebtReserveRemoved");
  await context.db
    .update(schema.debtReserve, { chainId: p.chainId, spoke: event.args.spoke, debtReserveId: event.args.reserveId })
    .set({ approved: false, lastBlock: p.blockNumber });
});

ponder.on("MarketRegistry:PauseStateChanged", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.PauseStateChanged");
  const state = enumName(PAUSE_STATE, event.args.current);
  await context.db
    .insert(schema.pauseState)
    .values({ chainId: p.chainId, hub: event.args.hub, state, reason: "None", lastBlock: p.blockNumber })
    .onConflictDoUpdate({ state, lastBlock: p.blockNumber });
});

ponder.on("MarketRegistry:PauseReasonChanged", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.PauseReasonChanged");
  const reason = enumName(PAUSE_REASON, event.args.current);
  await context.db
    .insert(schema.pauseState)
    .values({ chainId: p.chainId, hub: event.args.hub, state: "None", reason, lastBlock: p.blockNumber })
    .onConflictDoUpdate({ reason, lastBlock: p.blockNumber });
});

for (const [name, frozen] of [["AddressFrozen", true], ["AddressUnfrozen", false]] as const) {
  ponder.on(`MarketRegistry:${name}`, async ({ event, context }) => {
    const p = await recordLog(event, context, `MarketRegistry.${name}`);
    await context.db
      .insert(schema.frozenAddress)
      .values({ chainId: p.chainId, account: event.args.account, frozen, lastBlock: p.blockNumber })
      .onConflictDoUpdate({ frozen, lastBlock: p.blockNumber });
  });
}

ponder.on("MarketRegistry:BreakerLatched", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.BreakerLatched");
  const { scope, key, reasons } = event.args;
  await context.db
    .insert(schema.breaker)
    .values({ chainId: p.chainId, scope: Number(scope), key, latchedReasons: BigInt(reasons), lastBlock: p.blockNumber })
    .onConflictDoUpdate((row) => ({ latchedReasons: row.latchedReasons | BigInt(reasons), lastBlock: p.blockNumber }));
});

ponder.on("MarketRegistry:BreakerReset", async ({ event, context }) => {
  const p = await recordLog(event, context, "MarketRegistry.BreakerReset");
  await context.db
    .update(schema.breaker, { chainId: p.chainId, scope: Number(event.args.scope), key: event.args.key })
    .set({ latchedReasons: 0n, lastBlock: p.blockNumber });
});

// GateBreached carries no scope; the breach time per key is read live with MarketRegistry.lastBreachAt(key).
logOnly("MarketRegistry", [
  "GateBreached",
  "SpokeApproved",
  "TokenListed",
  "PriceSourceSet",
  "RouteSet",
  "RouteDisabled",
  "RouteRestored",
  "StandbyRouteActivated",
  "StandbySwitchCancelled",
  "PriceRouteRestored",
  "WindDownStepped",
  "HubRecorded",
  "IntegrationRegistered",
  "CoverageSpokeSet",
  "CrossHubLineSet",
  "CrossHubLinesEnabledSet",
  "FlashSourceSet",
  "CreditLineRecorded",
  "CreditLineSet",
  "SpokeCodeHashApproved",
  "IntegrationContractsRecorded",
]);
