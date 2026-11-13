// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Account attribution (AaveAdapter + ProxyManager) and the Spoke events of attributed accounts (TEST-144).
// A Spoke event for an address that neither creation event announced is logged and attributed to nobody.
// Attribution never uses the LiquidationCall `liquidator` field (LIQ-056).

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import type { Hex } from "viem";
import { AAVE_SPOKE_SOURCES } from "../config/aaveSources.ts";
import { type LogEventLike, recordLog } from "../lib/record.ts";

type Creation = { wallet: Hex; spoke: Hex; marketId: bigint; proxy: Hex };

async function announce(event: LogEventLike, context: Parameters<typeof recordLog>[1], kind: string, by: "adapter" | "manager") {
  const p = await recordLog(event, context, kind);
  const a = event.args as Creation;
  const flags = { adapterSeen: by === "adapter", managerSeen: by === "manager" };
  await context.db
    .insert(schema.account)
    .values({
      chainId: p.chainId,
      spoke: a.spoke,
      proxy: a.proxy,
      wallet: a.wallet,
      marketId: a.marketId,
      ...flags,
      usingAsCollateral: false,
      createdBlock: p.blockNumber,
      createdBlockHash: p.blockHash,
      createdTxHash: p.txHash,
      createdLogIndex: p.logIndex,
      lastBlock: p.blockNumber,
    })
    .onConflictDoUpdate((row) => {
      if (row.wallet !== a.wallet || row.marketId !== a.marketId) {
        throw new Error(`creation events disagree for proxy ${a.proxy} on chain ${p.chainId}`);
      }
      return by === "adapter" ? { adapterSeen: true, lastBlock: p.blockNumber } : { managerSeen: true, lastBlock: p.blockNumber };
    });
}

ponder.on("AaveAdapter:UserProxyCreated", async ({ event, context }) => {
  await announce(event, context, "AaveAdapter.UserProxyCreated", "adapter");
});

ponder.on("ProxyManager:ProxyDeployed", async ({ event, context }) => {
  await announce(event, context, "ProxyManager.ProxyDeployed", "manager");
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
