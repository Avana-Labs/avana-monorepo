/**
 * Borrow assets catalog — per-spoke borrowable asset records.
 * Replaces `listSpokeBorrowables()` in app/lib/borrow-system/registry.ts.
 */

import { v } from "convex/values"
import { internalMutation } from "../_generated/server"

const assetRow = {
  id: v.string(),
  spokeId: v.string(),
  baseAssetId: v.string(),
  name: v.string(),
  symbol: v.string(),
  subtitle: v.string(),
  category: v.string(),
  contextLabel: v.string(),
  displayVisual: v.object({
    symbol: v.string(),
    iconUrl: v.string(),
    shortLabel: v.string(),
    bgClass: v.string(),
    textClass: v.string(),
  }),
  baseBorrowAprPct: v.number(),
  totalCapacityUsd: v.number(),
  utilizationPct: v.number(),
  totalBorrowedUsd: v.number(),
  availableUsd: v.number(),
  reserveFactorPct: v.optional(v.number()),
  marketIds: v.array(v.string()),
}

export const upsertAssets = internalMutation({
  args: { rows: v.array(v.object(assetRow)) },
  handler: async (ctx, { rows }) => {
    const now = Date.now()
    for (const row of rows) {
      const existing = await ctx.db
        .query("borrowAssets")
        .withIndex("by_key", (q) => q.eq("id", row.id))
        .unique()
      if (existing) await ctx.db.patch(existing._id, { ...row, updatedAt: now })
      else await ctx.db.insert("borrowAssets", { ...row, updatedAt: now })
    }
    return { written: rows.length }
  },
})
