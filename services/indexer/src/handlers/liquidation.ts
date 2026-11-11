// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// LPVaultSwap settlements and registry, PayoutEscrow credits, flash liquidation helper calls.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { logOnly } from "../lib/logOnly.ts";
import { recordLog } from "../lib/record.ts";

ponder.on("LPVaultSwap:LiquidationSettled", async ({ event, context }) => {
  const p = await recordLog(event, context, "LPVaultSwap.LiquidationSettled");
  const { caller, proxy, marketId, report: r } = event.args;
  await context.db.insert(schema.liquidation).values({
    chainId: p.chainId,
    txHash: p.txHash,
    logIndex: p.logIndex,
    blockNumber: p.blockNumber,
    blockHash: p.blockHash,
    caller,
    proxy,
    marketId,
    debtReserveId: r.debtReserveId,
    debtAsset: r.debtAsset,
    debtRepaid: r.debtRepaid,
    unitsSeized: r.unitsSeized,
    recovered: r.recovered,
    minOut: r.minOut,
    callerFunds: r.callerFunds,
    avanaFee: r.avanaFee,
    borrowerSurplus: r.borrowerSurplus,
    keeperOut: r.keeperOut,
    minPayout: r.minPayout,
    shortfall: r.shortfall,
    routeMode: Number(r.routeMode),
  });
});

async function setOperator(chainId: number, operator: `0x${string}`, active: boolean, block: bigint, db: any) {
  await db
    .insert(schema.committedOperator)
    .values({ chainId, operator, active, lastBlock: block })
    .onConflictDoUpdate({ active, lastBlock: block });
}

ponder.on("LPVaultSwap:KeeperAdded", async ({ event, context }) => {
  const p = await recordLog(event, context, "LPVaultSwap.KeeperAdded");
  await setOperator(p.chainId, event.args.keeper, true, p.blockNumber, context.db);
});

ponder.on("LPVaultSwap:KeeperRemoved", async ({ event, context }) => {
  const p = await recordLog(event, context, "LPVaultSwap.KeeperRemoved");
  await setOperator(p.chainId, event.args.keeper, false, p.blockNumber, context.db);
});

logOnly("LPVaultSwap", [
  "BorrowerSurplusPaid",
  "FlashLoanUsed",
  "RouteFailed",
  "ResidueReturned",
  "PendingSettlementForwarded",
  "Deleveraged",
]);

ponder.on("PayoutEscrow:RemainderEscrowed", async ({ event, context }) => {
  const p = await recordLog(event, context, "PayoutEscrow.RemainderEscrowed");
  const { token, account, amount } = event.args;
  await context.db
    .insert(schema.escrowCredit)
    .values({ chainId: p.chainId, token, account, claimable: amount, lastBlock: p.blockNumber })
    .onConflictDoUpdate((row) => ({ claimable: row.claimable + amount, lastBlock: p.blockNumber }));
});

ponder.on("PayoutEscrow:RemainderClaimed", async ({ event, context }) => {
  const p = await recordLog(event, context, "PayoutEscrow.RemainderClaimed");
  const { token, account, amount } = event.args;
  await context.db
    .update(schema.escrowCredit, { chainId: p.chainId, token, account })
    .set((row) => ({ claimable: row.claimable - amount, lastBlock: p.blockNumber }));
});

logOnly("FlashLiquidator", ["FlashLiquidated"]);
