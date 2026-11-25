// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Account attribution (AaveAdapter.AccountCreated: one account proxy per wallet and market) and the Spoke events of
// attributed accounts. A Spoke event for an address the AaveAdapter did not announce is logged and attributed to
// nobody. Attribution never uses the LiquidationCall `liquidator` field (LIQ-056).

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import type { Hex } from "viem";
import { AAVE_SPOKE_SOURCES } from "../config/aaveSources.ts";
import { stackIntegration } from "../config/integrations.ts";
import { type LogEventLike, recordLog } from "../lib/record.ts";

ponder.on("AaveAdapter:AccountCreated", async ({ event, context }) => {
  const p = await recordLog(event, context, "AaveAdapter.AccountCreated");
  const { wallet, marketId, account } = event.args;
  // The market is the emitting AaveAdapter's integration's: market IDs are numbered per RiskModule.
  const integrationId = stackIntegration(p.chainId, "aaveAdapter", event.log.address);
  // The market's Spoke keys the account; a market is listed before any account of it exists (fail closed otherwise).
  const market = await context.db.find(schema.market, { chainId: p.chainId, integrationId, marketId });
  if (!market?.spoke) throw new Error(`AccountCreated for market ${integrationId}:${marketId} on chain ${p.chainId} before its PoolListed`);
  await context.db
    .insert(schema.account)
    .values({
      chainId: p.chainId,
      spoke: market.spoke,
      proxy: account,
      wallet,
      integrationId,
      marketId,
      adapter: event.log.address,
      usingAsCollateral: false,
      createdBlock: p.blockNumber,
      createdBlockHash: p.blockHash,
      createdTxHash: p.txHash,
      createdLogIndex: p.logIndex,
      lastBlock: p.blockNumber,
    })
    .onConflictDoNothing();
});

for (const source of AAVE_SPOKE_SOURCES) {
  ponder.on(`${source}:SetUsingAsCollateral`, async ({ event, context }) => {
    const p = await recordLog(event, context, "AaveSpoke.SetUsingAsCollateral");
    const key = { chainId: p.chainId, spoke: event.log.address, proxy: event.args.user };
    if (!p.fresh || !(await context.db.find(schema.account, key))) return;
    await context.db.update(schema.account, key).set({ usingAsCollateral: event.args.usingAsCollateral, lastBlock: p.blockNumber });
  });
}

/** Adds `delta` drawn shares to an attributed account's debt row; `deficit` marks a ReportDeficit. */
async function moveDebt(
  event: LogEventLike,
  context: Parameters<typeof recordLog>[1],
  kind: string,
  user: Hex,
  debtReserveId: bigint,
  delta: bigint,
  deficit: boolean,
) {
  const p = await recordLog(event, context, kind);
  const spoke = event.log.address;
  // A second source delivering the same log must not move the debt again.
  if (!p.fresh || !(await context.db.find(schema.account, { chainId: p.chainId, spoke, proxy: user }))) return;
  const stamp = { lastBlock: p.blockNumber, lastBlockHash: p.blockHash, lastLogIndex: p.logIndex };
  await context.db
    .insert(schema.accountDebt)
    .values({ chainId: p.chainId, spoke, proxy: user, debtReserveId, drawnShares: delta, deficitReported: deficit, ...stamp })
    .onConflictDoUpdate((row) => ({
      drawnShares: deficit ? 0n : row.drawnShares + delta,
      deficitReported: row.deficitReported || deficit,
      ...stamp,
    }));
}

for (const source of AAVE_SPOKE_SOURCES) {
  ponder.on(`${source}:Borrow`, async ({ event, context }) => {
    const a = event.args;
    await moveDebt(event, context, "AaveSpoke.Borrow", a.user, a.reserveId, a.drawnShares, false);
  });

  ponder.on(`${source}:Repay`, async ({ event, context }) => {
    const a = event.args;
    await moveDebt(event, context, "AaveSpoke.Repay", a.user, a.reserveId, -a.drawnShares, false);
  });

  ponder.on(`${source}:LiquidationCall`, async ({ event, context }) => {
    const a = event.args;
    await moveDebt(event, context, "AaveSpoke.LiquidationCall", a.user, a.debtReserveId, -a.drawnSharesLiquidated, false);
  });

  ponder.on(`${source}:ReportDeficit`, async ({ event, context }) => {
    const a = event.args;
    await moveDebt(event, context, "AaveSpoke.ReportDeficit", a.user, a.reserveId, 0n, true);
  });
}
