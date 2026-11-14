/**
 * Fee APY wads per market (1e18-scaled bigint stored as string). Public read —
 * fee rates are derived from public marketDailyStats; upsert is internal-only.
 *
 * Values stored as strings because Convex can't serialize bigint natively; the
 * caller parses back to bigint (see app/lib/credit-engine accrual helpers).
 */

import { v } from "convex/values"
import { internalMutation, query } from "../_generated/server"

export const getFeeApy = query({
  args: { slug: v.string() },
  handler: async (ctx, { slug }) => {
    const row = await ctx.db
      .query("feeApyWads")
      .withIndex("by_slug", (q) => q.eq("slug", slug))
      .unique()
    return row ? { slug: row.slug, feeApyWad: row.feeApyWad, updatedAt: row.updatedAt } : null
  },
})

export const listFeeApys = query({
  args: {},
  handler: async (ctx) => {
    const rows = await ctx.db.query("feeApyWads").collect()
    return rows.map((row) => ({ slug: row.slug, feeApyWad: row.feeApyWad, updatedAt: row.updatedAt }))
  },
})

export const upsertFeeApys = internalMutation({
  args: {
    rows: v.array(v.object({ slug: v.string(), feeApyWad: v.string() })),
  },
  handler: async (ctx, { rows }) => {
    const now = Date.now()
    for (const row of rows) {
      const existing = await ctx.db
        .query("feeApyWads")
        .withIndex("by_slug", (q) => q.eq("slug", row.slug))
        .unique()
      if (existing) {
        await ctx.db.patch(existing._id, { feeApyWad: row.feeApyWad, updatedAt: now })
      } else {
        await ctx.db.insert("feeApyWads", { slug: row.slug, feeApyWad: row.feeApyWad, updatedAt: now })
      }
    }
    return { written: rows.length }
  },
})
