// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Liquidations (LiquidationModule, with the FlashLiquidator's flash-loan figures when one ran it) and repayments with
// collateral (FlashloanRepay).

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { recordLog } from "../lib/record.ts";

ponder.on("LiquidationModule:Liquidated", async ({ event, context }) => {
  const p = await recordLog(event, context, "LiquidationModule.Liquidated");
  const a = event.args;
  await context.db
    .insert(schema.liquidation)
    .values({
      chainId: p.chainId,
      txHash: p.txHash,
      logIndex: p.logIndex,
      blockNumber: p.blockNumber,
      blockHash: p.blockHash,
      liquidationModule: event.log.address,
      account: a.account,
      marketId: a.marketId,
      liquidator: a.liquidator,
      debtReserveId: a.debtReserveId,
      debtRepaid: a.debtRepaid,
      seized: a.seized,
      creditUnwound: a.creditUnwound,
      amount0: a.amount0,
      amount1: a.amount1,
      feeUnits: 0n,
      fee0: 0n,
      fee1: 0n,
    })
    .onConflictDoNothing();
  const key = { chainId: p.chainId, txHash: p.txHash, account: a.account, marketId: a.marketId };
  await context.db.insert(schema.liquidationInTx).values({ ...key, logIndex: p.logIndex }).onConflictDoUpdate({ logIndex: p.logIndex });
});

/** The logIndex of the latest liquidation of (account, market) earlier in the same transaction, or undefined. */
async function liquidationOf(context: Parameters<typeof recordLog>[1], chainId: number, txHash: `0x${string}`, account: `0x${string}`, marketId: bigint) {
  return (await context.db.find(schema.liquidationInTx, { chainId, txHash, account, marketId }))?.logIndex;
}

// `FeePaid` follows its `Liquidated` in the same call: the Avana fee of that liquidation.
ponder.on("LiquidationModule:FeePaid", async ({ event, context }) => {
  const p = await recordLog(event, context, "LiquidationModule.FeePaid");
  const a = event.args;
  const logIndex = await liquidationOf(context, p.chainId, p.txHash, a.account, a.marketId);
  if (logIndex === undefined) throw new Error(`FeePaid on chain ${p.chainId} in ${p.txHash} without its Liquidated`);
  await context.db
    .update(schema.liquidation, { chainId: p.chainId, txHash: p.txHash, logIndex })
    .set({ feeUnits: a.units, fee0: a.fee0, fee1: a.fee1 });
});

// A FlashLiquidator emits `FlashLiquidated` after the liquidation it funded, in the same transaction.
ponder.on("FlashLiquidator:FlashLiquidated", async ({ event, context }) => {
  const p = await recordLog(event, context, "FlashLiquidator.FlashLiquidated");
  const a = event.args;
  const logIndex = await liquidationOf(context, p.chainId, p.txHash, a.account, a.marketId);
  if (logIndex === undefined) throw new Error(`FlashLiquidated on chain ${p.chainId} in ${p.txHash} without its Liquidated`);
  await context.db
    .update(schema.liquidation, { chainId: p.chainId, txHash: p.txHash, logIndex })
    .set({ flashAmount: a.flashAmount, flashPremium: a.premium, topUp: a.topUp, profit: a.profit });
});

ponder.on("FlashloanRepay:RepaidWithCollateral", async ({ event, context }) => {
  const p = await recordLog(event, context, "FlashloanRepay.RepaidWithCollateral");
  const a = event.args;
  await context.db
    .insert(schema.collateralRepay)
    .values({
      chainId: p.chainId,
      txHash: p.txHash,
      logIndex: p.logIndex,
      blockNumber: p.blockNumber,
      flashloanRepay: event.log.address,
      wallet: a.wallet,
      positionKey: a.positionKey,
      asset: a.asset,
      repaid: a.repaid,
      premium: a.premium,
      liquidity: a.liquidity,
    })
    .onConflictDoNothing();
});
