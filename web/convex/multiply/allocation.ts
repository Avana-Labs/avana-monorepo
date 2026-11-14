/**
 * Multiply product — per-market allocation across contributing pools.
 * Table: `multiplyMarketAllocations`.
 *
 * Currently missing on multiply detail — the allocation card renders nothing
 * or a silent mock. This query mirrors the borrow allocation shape so the
 * client swap in Phase E is a one-line reader change.
 */

import { v } from "convex/values"
import { internalMutation } from "../_generated/server"

export const upsertAllocation = internalMutation({
  args: {
    rows: v.array(
      v.object({
        marketSlug: v.string(),
        rowKey: v.string(),
        poolSlug: v.string(),
        poolName: v.string(),
        venueLabel: v.string(),
        sharePct: v.number(),
        valueUsd: v.number(),
        utilizationPct: v.number(),
        borrowAprPct: v.number(),
        collateralFactorPct: v.number(),
      }),
    ),
  },
  handler: async (ctx, { rows }) => {
    const now = Date.now()
    for (const row of rows) {
      const existing = await ctx.db
        .query("multiplyMarketAllocations")
        .withIndex("by_market", (q) => q.eq("marketSlug", row.marketSlug))
        .filter((q) => q.eq(q.field("rowKey"), row.rowKey))
        .unique()
      if (existing) await ctx.db.patch(existing._id, { ...row, updatedAt: now })
      else await ctx.db.insert("multiplyMarketAllocations", { ...row, updatedAt: now })
    }
    return { written: rows.length }
  },
})

/** Delete every allocation row for a market (used when reseeding). */
export const clearAllocation = internalMutation({
  args: { marketSlug: v.string() },
  handler: async (ctx, { marketSlug }) => {
    const rows = await ctx.db
      .query("multiplyMarketAllocations")
      .withIndex("by_market", (q) => q.eq("marketSlug", marketSlug))
      .collect()
    for (const row of rows) await ctx.db.delete(row._id)
    return { deleted: rows.length }
  },
})
