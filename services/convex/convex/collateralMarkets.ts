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

export const get = query({
  args: { chainId: v.number(), marketId: v.string() },
  handler: async (ctx, k) => {
    const market = await ctx.db.query("markets").withIndex("by_key", (q) => q.eq("chainId", k.chainId).eq("marketId", k.marketId)).unique();
    if (!market) return null;
    const debts = await ctx.db.query("marketReserveDebt").withIndex("by_market", (q) => q.eq("chainId", k.chainId).eq("marketId", k.marketId)).collect();
    return { market, debts };
  },
});
