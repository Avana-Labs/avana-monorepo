// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The frontend fee and the total shown before signing: the fee rate and rules from `feeConfig` (10 bps on every app
// action by default, never above MAX_FEE_BPS), the gas of the simulated batch at the chain's current gas price, and
// the fee token's Lend Spoke price. The app adds the fee transfer to the action's batch with the amount `quote`
// returns (lib/fees.ts computes both), sent to the ParameterStore's `feeRecipient` that the app reads on chain; Convex
// holds no recipient.

import { v } from "convex/values";
import { internalMutation, query, type QueryCtx } from "./_generated/server";
import { checkFeeRules, DEFAULT_FEE_RULES, type FeeAction, type FeeRules, LP_VALUE_ACTIONS, MAX_FEE_BPS, quoteFee } from "./lib/fees.ts";

const action = v.union(
  v.literal("supply"),
  v.literal("withdraw"),
  v.literal("pledge"),
  v.literal("borrow"),
  v.literal("repay"),
  v.literal("withdrawCollateral"),
  v.literal("repayWithCollateral"),
  v.literal("deleverage"),
  v.literal("swap"),
);

async function rules(ctx: QueryCtx): Promise<FeeRules> {
  const row = await ctx.db.query("feeConfig").withIndex("by_key", (q) => q.eq("key", "default")).unique();
  return row ? { enabled: row.enabled, defaultBps: row.defaultBps, actionBps: row.actionBps, exemptActions: row.exemptActions, maxFeeUsd: row.maxFeeUsd } : DEFAULT_FEE_RULES;
}

export const getConfig = query({ args: {}, handler: async (ctx) => ({ ...(await rules(ctx)), maxBps: MAX_FEE_BPS }) });

/** The fee token's Lend Spoke price: the action token, or for pledge and withdraw collateral the debt stablecoin. */
async function priceOf(ctx: QueryCtx, chainId: number, token: string): Promise<{ decimals: number; priceUsd8: bigint } | null> {
  const asset = await ctx.db.query("hubAssets").withIndex("by_chain_underlying", (q) => q.eq("chainId", chainId).eq("underlying", token)).first();
  return asset ? { decimals: asset.decimals, priceUsd8: BigInt(asset.priceUsd8) } : null;
}

export const quote = query({
  args: {
    chainId: v.number(),
    action,
    /** The token the fee is paid in: the action token, or for pledge and withdraw collateral the market's debt stablecoin. */
    token: v.string(),
    /** Action amount in base units, decimal string; every action except pledge and withdraw collateral. */
    amount: v.optional(v.string()),
    /** The position's LPOracle value from Lens, USD with 8 decimals, decimal string; pledge and withdraw collateral. */
    positionValueUsd8: v.optional(v.string()),
    /** Gas of the whole batch (action and fee transfer) from the wallet's simulation. */
    gasUnits: v.string(),
    /** L1 data fee of the batch on an L2, wei. */
    l1FeeWei: v.optional(v.string()),
  },
  handler: async (ctx, a) => {
    const lp = LP_VALUE_ACTIONS.has(a.action as FeeAction);
    const input = lp ? a.positionValueUsd8 : a.amount;
    if (input === undefined) throw new Error(`${a.action} needs ${lp ? "positionValueUsd8" : "amount"}`);
    const price = await priceOf(ctx, a.chainId, a.token.toLowerCase());
    if (!price) return null;
    const gas = await ctx.db.query("chainGas").withIndex("by_chain", (q) => q.eq("chainId", a.chainId)).unique();
    if (!gas) return null;
    const q = quoteFee(await rules(ctx), {
      action: a.action as FeeAction,
      basis: lp
        ? { kind: "lpValue", valueUsd8: BigInt(input), decimals: price.decimals, priceUsd8: price.priceUsd8 }
        : { kind: "amount", amount: BigInt(input), decimals: price.decimals, priceUsd8: price.priceUsd8 },
      gas: { gasUnits: BigInt(a.gasUnits), baseFeeWei: BigInt(gas.baseFeeWei), priorityFeeWei: BigInt(gas.priorityFeeWei), l1FeeWei: BigInt(a.l1FeeWei ?? "0"), nativeUsd8: BigInt(gas.nativeUsd8) },
    });
    return { ...q, feeAmount: q.feeAmount.toString(), gasWei: q.gasWei.toString(), priceUsd8: price.priceUsd8.toString(), gasUpdatedAt: gas.updatedAt };
  },
});

/** Sets the fee rules; run from the Convex dashboard or CLI by an operator (internal: no client can call it). Any rate above MAX_FEE_BPS throws. */
export const setConfig = internalMutation({
  args: { enabled: v.boolean(), defaultBps: v.number(), actionBps: v.record(v.string(), v.number()), exemptActions: v.array(v.string()), maxFeeUsd: v.union(v.null(), v.number()) },
  handler: async (ctx, a) => {
    checkFeeRules(a);
    const row = { key: "default", ...a, updatedAt: Date.now() };
    const existing = await ctx.db.query("feeConfig").withIndex("by_key", (q) => q.eq("key", "default")).unique();
    if (existing) await ctx.db.replace(existing._id, row);
    else await ctx.db.insert("feeConfig", row);
  },
});
