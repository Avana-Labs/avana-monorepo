// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The frontend fee and the total shown before signing: the fee rate and rules from `feeConfig`, the gas of the
// simulated batch at the chain's current gas price, and the token's Lend Spoke price. The app adds the fee transfer
// to the action's batch with the amount `quote` returns (lib/fees.ts computes both).

import { v } from "convex/values";
import { internalMutation, query, type QueryCtx } from "./_generated/server";
import { DEFAULT_FEE_RULES, type FeeAction, type FeeRules, quoteFee } from "./lib/fees.ts";

const action = v.union(
  v.literal("supply"),
  v.literal("withdraw"),
  v.literal("pledge"),
  v.literal("borrow"),
  v.literal("repay"),
  v.literal("withdrawCollateral"),
  v.literal("repayWithCollateral"),
  v.literal("swap"),
);

async function rules(ctx: QueryCtx): Promise<FeeRules> {
  const row = await ctx.db.query("feeConfig").withIndex("by_key", (q) => q.eq("key", "default")).unique();
  return row ? { enabled: row.enabled, defaultBps: row.defaultBps, actionBps: row.actionBps, exemptActions: row.exemptActions, maxFeeUsd: row.maxFeeUsd } : DEFAULT_FEE_RULES;
}

export const getConfig = query({ args: {}, handler: async (ctx) => rules(ctx) });

/** The token's Lend Spoke price, or for a vault token its market's accepted LP price. */
async function priceOf(ctx: QueryCtx, chainId: number, token: string): Promise<{ decimals: number; priceUsd8: bigint } | null> {
  const asset = await ctx.db.query("hubAssets").withIndex("by_chain_underlying", (q) => q.eq("chainId", chainId).eq("underlying", token)).first();
  if (asset) return { decimals: asset.decimals, priceUsd8: BigInt(asset.priceUsd8) };
  const market = (await ctx.db.query("markets").collect()).find((m) => m.chainId === chainId && m.vaultToken === token);
  return market ? { decimals: market.vaultDecimals, priceUsd8: BigInt(market.acceptedPrice) } : null;
}

export const quote = query({
  args: {
    chainId: v.number(),
    action,
    token: v.string(),
    /** Base units, decimal string. */
    amount: v.string(),
    /** Gas of the whole batch (action and fee transfer) from the wallet's simulation. */
    gasUnits: v.string(),
    /** L1 data fee of the batch on an L2, wei. */
    l1FeeWei: v.optional(v.string()),
  },
  handler: async (ctx, a) => {
    const price = await priceOf(ctx, a.chainId, a.token.toLowerCase());
    if (!price) return null;
    const gas = await ctx.db.query("chainGas").withIndex("by_chain", (q) => q.eq("chainId", a.chainId)).unique();
    if (!gas) return null;
    const q = quoteFee(await rules(ctx), {
      action: a.action as FeeAction,
      amount: BigInt(a.amount),
      decimals: price.decimals,
      priceUsd8: price.priceUsd8,
      gas: { gasUnits: BigInt(a.gasUnits), baseFeeWei: BigInt(gas.baseFeeWei), priorityFeeWei: BigInt(gas.priorityFeeWei), l1FeeWei: BigInt(a.l1FeeWei ?? "0"), nativeUsd8: BigInt(gas.nativeUsd8) },
    });
    return { ...q, feeAmount: q.feeAmount.toString(), gasWei: q.gasWei.toString(), priceUsd8: price.priceUsd8.toString(), gasUpdatedAt: gas.updatedAt };
  },
});

/** Sets the fee rules; run from the Convex dashboard or CLI by an operator (internal: no client can call it). */
export const setConfig = internalMutation({
  args: { enabled: v.boolean(), defaultBps: v.number(), actionBps: v.record(v.string(), v.number()), exemptActions: v.array(v.string()), maxFeeUsd: v.union(v.null(), v.number()) },
  handler: async (ctx, a) => {
    for (const bps of [a.defaultBps, ...Object.values(a.actionBps)]) if (!Number.isInteger(bps) || bps < 0 || bps > 10_000) throw new Error(`fee rate ${bps} bps outside 0..10000`);
    const row = { key: "default", ...a, updatedAt: Date.now() };
    const existing = await ctx.db.query("feeConfig").withIndex("by_key", (q) => q.eq("key", "default")).unique();
    if (existing) await ctx.db.replace(existing._id, row);
    else await ctx.db.insert("feeConfig", row);
  },
});
