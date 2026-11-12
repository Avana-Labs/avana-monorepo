// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Hub assets by scope key: one row per (chain, Hub, asset), so the same token on two Hubs is two rows, read by the
// Lend page and by the Hub block of every Borrow asset page. `allocation` returns the asset's Spoke slices with the
// reconciliation of their sums to the Hub totals at the same block.

import { v } from "convex/values";
import { reconcileHubAsset } from "@avana/services-common/views";
import { query } from "./_generated/server";
import { spokeAllocation } from "./lib/pages.ts";
import { asRows } from "./model.ts";

const key = { chainId: v.number(), hub: v.string(), assetId: v.string() };

export const list = query({
  args: { chainId: v.optional(v.number()), hub: v.optional(v.string()) },
  handler: async (ctx, { chainId, hub }) => {
    if (chainId !== undefined && hub !== undefined) return ctx.db.query("hubAssets").withIndex("by_hub", (q) => q.eq("chainId", chainId).eq("hub", hub.toLowerCase())).collect();
    return (await ctx.db.query("hubAssets").collect()).filter((a) => (chainId === undefined || a.chainId === chainId) && (hub === undefined || a.hub === hub.toLowerCase()));
  },
});

export const get = query({
  args: key,
  handler: async (ctx, k) => ctx.db.query("hubAssets").withIndex("by_key", (q) => q.eq("chainId", k.chainId).eq("hub", k.hub.toLowerCase()).eq("assetId", k.assetId)).unique(),
});

export const allocation = query({
  args: key,
  handler: async (ctx, k) => {
    const hub = k.hub.toLowerCase();
    const asset = await ctx.db.query("hubAssets").withIndex("by_key", (q) => q.eq("chainId", k.chainId).eq("hub", hub).eq("assetId", k.assetId)).unique();
    if (!asset) return null;
    const slices = await ctx.db.query("hubAssetSpokes").withIndex("by_asset", (q) => q.eq("chainId", k.chainId).eq("hub", hub).eq("assetId", k.assetId)).collect();
    const [a] = asRows.hubAssets([asset]);
    const typed = asRows.slices(slices);
    const r = reconcileHubAsset(a!, typed);
    return {
      slices,
      ...spokeAllocation(a!, typed),
      reconciliation: {
        hubOwed: r.hubOwed.toString(),
        cdpOwed: r.cdpOwed.toString(),
        owedReconciles: r.owedReconciles,
        hubAdded: r.hubAdded.toString(),
        slicesAdded: r.slicesAdded.toString(),
        addedReconciles: r.addedReconciles,
        onlyCdpDraws: r.onlyCdpDraws,
        balanceHolds: r.balanceHolds,
      },
    };
  },
});
