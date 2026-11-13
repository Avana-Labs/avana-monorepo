// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// CDP debt reserves by scope key, each joined (not copied) to its Spoke slice and the key of its Hub asset; the page
// then reads that Hub asset with `hubAssets.get`, the same document the Lend page reads.

import { v } from "convex/values";
import { query, type QueryCtx } from "./_generated/server";
import type { Doc } from "./_generated/dataModel";

async function join(ctx: QueryCtx, r: Doc<"spokeReserves">) {
  const slice = await ctx.db
    .query("hubAssetSpokes")
    .withIndex("by_key", (q) => q.eq("chainId", r.chainId).eq("hub", r.hub).eq("assetId", r.assetId).eq("spoke", r.spoke))
    .unique();
  return { reserve: r, slice, hubAssetKey: { chainId: r.chainId, hub: r.hub, assetId: r.assetId } };
}

export const list = query({
  args: { chainId: v.optional(v.number()), spoke: v.optional(v.string()) },
  handler: async (ctx, { chainId, spoke }) => {
    const rows = (await ctx.db.query("spokeReserves").collect()).filter((r) => (chainId === undefined || r.chainId === chainId) && (spoke === undefined || r.spoke === spoke.toLowerCase()));
    return Promise.all(rows.map((r) => join(ctx, r)));
  },
});

export const get = query({
  args: { chainId: v.number(), spoke: v.string(), reserveId: v.string() },
  handler: async (ctx, k) => {
    const r = await ctx.db.query("spokeReserves").withIndex("by_key", (q) => q.eq("chainId", k.chainId).eq("spoke", k.spoke.toLowerCase()).eq("reserveId", k.reserveId)).unique();
    return r ? join(ctx, r) : null;
  },
});

/** The reserve's owed amount by market: Σ rows equals the Spoke slice's owed amount up to one unit per account. */
export const byMarket = query({
  args: { chainId: v.number(), spoke: v.string(), reserveId: v.string() },
  handler: async (ctx, k) => {
    const debts = await ctx.db.query("marketReserveDebt").withIndex("by_reserve", (q) => q.eq("chainId", k.chainId).eq("spoke", k.spoke.toLowerCase()).eq("reserveId", k.reserveId)).collect();
    return Promise.all(
      debts.map(async (d) => ({ debt: d, market: await ctx.db.query("markets").withIndex("by_key", (q) => q.eq("chainId", d.chainId).eq("marketId", d.marketId)).unique() })),
    );
  },
});
