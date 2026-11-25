// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// RiskModule listing: every pool's two markets (Full range and Custom range), their activation, the debt reserves
// with their First-Loss Reserves, and the keeper registry. The pool a pair of markets lists starts its series here.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { clPoolAbi } from "@avana/services-common/views";
import { integrationOfRiskModule, poolAddressOf } from "../config/integrations.ts";
import { enumName, logOnly } from "../lib/logOnly.ts";
import { recordLog } from "../lib/record.ts";
import { stateReadBlock } from "../lib/stateFloor.ts";

/** `IRiskModule.MarketKind`. */
export const MARKET_KIND = ["full-range", "custom-range"] as const;

/** The integration of the RiskModule that emitted a log; a RiskModule the manifest does not list stops the indexer. */
function integrationOf(chainId: number, riskModule: string) {
  const x = integrationOfRiskModule(chainId, riskModule);
  if (!x) throw new Error(`RiskModule ${riskModule} on chain ${chainId} is not in the manifest`);
  return x;
}

ponder.on("RiskModule:MarketListed", async ({ event, context }) => {
  const p = await recordLog(event, context, "RiskModule.MarketListed");
  if (!p.fresh) return;
  const a = event.args;
  await context.db.insert(schema.market).values({
    chainId: p.chainId,
    integrationId: integrationOf(p.chainId, event.log.address).integrationId,
    marketId: a.marketId,
    riskModule: event.log.address,
    pool: a.pool,
    kind: enumName(MARKET_KIND, a.kind),
    bandLower: Number(a.bandLower),
    bandUpper: Number(a.bandUpper),
    unitDecimals: Number(a.unitDecimals),
    active: false,
    listedBlock: p.blockNumber,
    lastBlock: p.blockNumber,
  });
});

ponder.on("RiskModule:PoolListed", async ({ event, context }) => {
  const p = await recordLog(event, context, "RiskModule.PoolListed");
  const a = event.args;
  const { integrationId, kind } = integrationOf(p.chainId, event.log.address);
  const row = { spoke: a.spoke, listingTick: Number(a.listingTick), ltvBps: Number(a.ltvBps), lastBlock: p.blockNumber };
  for (const marketId of [a.fullRange, a.customRange]) await context.db.update(schema.market, { chainId: p.chainId, integrationId, marketId }).set(row);
  // The pool's series start here. A Uniswap v4 pool is a PoolId the PoolManager handlers follow; a concentrated-
  // liquidity pool is the address in the key, whose fee is read once (a dynamic-fee pool is re-read by the sampler).
  if (kind === "uniswap-v4") {
    await context.db
      .insert(schema.ammPoolId)
      .values({ chainId: p.chainId, poolId: a.pool.toLowerCase() as `0x${string}`, integrationId, listedBlock: p.blockNumber, lastBlock: p.blockNumber })
      .onConflictDoNothing();
    return;
  }
  const pool = poolAddressOf(a.pool);
  // At the log's block, or at the state floor of a restored development node (lib/stateFloor.ts).
  const fee = await context.client.readContract({ address: pool, abi: clPoolAbi, functionName: "fee", blockNumber: stateReadBlock(p.chainId, p.blockNumber) });
  await context.db
    .insert(schema.ammPool)
    .values({ chainId: p.chainId, pool, integrationId, feePips: Number(fee), listedBlock: p.blockNumber, lastBlock: p.blockNumber })
    .onConflictDoNothing();
});

ponder.on("RiskModule:MarketActivated", async ({ event, context }) => {
  const p = await recordLog(event, context, "RiskModule.MarketActivated");
  const a = event.args;
  const { integrationId } = integrationOf(p.chainId, event.log.address);
  await context.db
    .update(schema.market, { chainId: p.chainId, integrationId, marketId: a.marketId })
    .set({ active: true, vaultToken: a.vaultToken, lpOracle: a.lpOracle, reserveId: a.reserveId, lastBlock: p.blockNumber });
});

ponder.on("RiskModule:DebtReserveSet", async ({ event, context }) => {
  const p = await recordLog(event, context, "RiskModule.DebtReserveSet");
  const a = event.args;
  const row = { hub: a.hub, asset: a.asset, firstLossReserve: a.firstLossReserve, listed: true, lastBlock: p.blockNumber };
  await context.db
    .insert(schema.debtReserve)
    .values({ chainId: p.chainId, riskModule: event.log.address, spoke: a.spoke, debtReserveId: a.reserveId, ...row })
    .onConflictDoUpdate(row);
});

ponder.on("RiskModule:DebtReserveRemoved", async ({ event, context }) => {
  const p = await recordLog(event, context, "RiskModule.DebtReserveRemoved");
  await context.db
    .update(schema.debtReserve, { chainId: p.chainId, riskModule: event.log.address, spoke: event.args.spoke, debtReserveId: event.args.reserveId })
    .set({ listed: false, lastBlock: p.blockNumber });
});

for (const [name, active] of [["KeeperAdded", true], ["KeeperRemoved", false]] as const) {
  ponder.on(`RiskModule:${name}`, async ({ event, context }) => {
    const p = await recordLog(event, context, `RiskModule.${name}`);
    await context.db
      .insert(schema.keeper)
      .values({ chainId: p.chainId, riskModule: event.log.address, keeper: event.args.keeper, active, lastBlock: p.blockNumber })
      .onConflictDoUpdate({ active, lastBlock: p.blockNumber });
  });
}

logOnly("RiskModule", ["SpokeRegistered", "SpokeWidthSet", "CoverageRatioSet", "FeeSet"]);
