// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Stores validated listing metadata: one `marketContent` row per entry (a later listing replaces an earlier one for
// the same key), and the page slug on the scope row it names, so the page is reachable under its listed slug.

import { v } from "convex/values";
import { internalMutation } from "../_generated/server";
import type { MetadataEntry } from "../lib/metadata.ts";

export const mark = internalMutation({
  args: { chainId: v.number(), operationId: v.string(), status: v.union(v.literal("noMetadata"), v.literal("rejected")), error: v.optional(v.string()) },
  handler: async (ctx, a) => {
    const op = await ctx.db.query("listingOperations").withIndex("by_op", (q) => q.eq("chainId", a.chainId).eq("operationId", a.operationId)).unique();
    if (op) await ctx.db.patch(op._id, { status: a.status, ...(a.error ? { error: a.error } : {}), updatedAt: Date.now() });
  },
});

export const store = internalMutation({
  args: { chainId: v.number(), operationId: v.string(), contentHash: v.string(), entries: v.any() },
  handler: async (ctx, { chainId, operationId, contentHash, entries }) => {
    const now = Date.now();
    for (const e of entries as MetadataEntry[]) {
      const row = {
        scope: e.scope,
        chainId,
        key: e.key,
        slug: e.slug,
        name: e.name,
        ...(e.symbol ? { symbol: e.symbol } : {}),
        ...(e.category ? { category: e.category } : {}),
        ...(e.venueLabel ? { venueLabel: e.venueLabel } : {}),
        ...(e.iconUrl ? { iconUrl: e.iconUrl } : {}),
        description: e.description,
        ...(e.longText ? { longText: e.longText } : {}),
        stats: [...e.stats],
        history: [...e.history],
        faqs: [...e.faqs],
        ...(e.visuals ? { visuals: [...e.visuals] } : {}),
        ...(e.resources ? { resources: [...e.resources] } : {}),
        contentHash,
        operationId,
        loadedAt: now,
      };
      const existing = await ctx.db.query("marketContent").withIndex("by_key", (q) => q.eq("scope", e.scope).eq("chainId", chainId).eq("key", e.key)).unique();
      if (existing) await ctx.db.replace(existing._id, row);
      else await ctx.db.insert("marketContent", row);
      if (e.scope === "lend") {
        const [hub, assetId] = e.key.split(":") as [string, string];
        const a = await ctx.db.query("hubAssets").withIndex("by_key", (q) => q.eq("chainId", chainId).eq("hub", hub).eq("assetId", assetId)).unique();
        if (a) await ctx.db.patch(a._id, { slug: e.slug });
      } else if (e.scope === "asset") {
        const [spoke, reserveId] = e.key.split(":") as [string, string];
        const r = await ctx.db.query("spokeReserves").withIndex("by_key", (q) => q.eq("chainId", chainId).eq("spoke", spoke).eq("reserveId", reserveId)).unique();
        if (r) await ctx.db.patch(r._id, { slug: e.slug });
      } else if (e.scope === "pool") {
        const m = await ctx.db.query("markets").withIndex("by_key", (q) => q.eq("chainId", chainId).eq("marketId", e.key)).unique();
        if (m) await ctx.db.patch(m._id, { slug: e.slug });
      }
    }
    const op = await ctx.db.query("listingOperations").withIndex("by_op", (q) => q.eq("chainId", chainId).eq("operationId", operationId)).unique();
    if (op) await ctx.db.patch(op._id, { status: "loaded", updatedAt: now });
  },
});
