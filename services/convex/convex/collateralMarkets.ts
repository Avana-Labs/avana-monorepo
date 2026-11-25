// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Collateral markets by scope key, with the debt each backs per debt reserve.

import { v } from "convex/values";
import { query } from "./_generated/server";

export const list = query({
  args: { chainId: v.optional(v.number()), spoke: v.optional(v.string()) },
  handler: async (ctx, { chainId, spoke }) =>
    (await ctx.db.query("markets").collect()).filter((m) => (chainId === undefined || m.chainId === chainId) && (spoke === undefined || m.spoke === spoke.toLowerCase())),
});

/**
 * One market by `integrationId` and `marketId` (each integration's RiskModule numbers its own markets from 1). Without
 * `integrationId` the market ID must be listed by one integration only on the chain; an ID two integrations list is
 * refused rather than answered with either.
 */
export const get = query({
  args: { chainId: v.number(), integrationId: v.optional(v.number()), marketId: v.string() },
  handler: async (ctx, k) => {
    const candidates =
      k.integrationId === undefined
        ? (await ctx.db.query("markets").withIndex("by_key", (q) => q.eq("chainId", k.chainId)).collect()).filter((m) => m.marketId === k.marketId)
        : await ctx.db.query("markets").withIndex("by_key", (q) => q.eq("chainId", k.chainId).eq("integrationId", k.integrationId!).eq("marketId", k.marketId)).collect();
    if (candidates.length > 1) throw new Error(`market ${k.marketId} on chain ${k.chainId} is listed by integrations ${candidates.map((m) => m.integrationId).join(", ")}: pass integrationId`);
    const market = candidates[0];
    if (!market) return null;
    const debts = await ctx.db
      .query("marketReserveDebt")
      .withIndex("by_market", (q) => q.eq("chainId", k.chainId).eq("integrationId", market.integrationId).eq("marketId", k.marketId))
      .collect();
    return { market, debts };
  },
});
