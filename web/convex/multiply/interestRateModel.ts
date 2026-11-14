/**
 * Multiply product — Interest Rate Model params for market detail pages.
 * Table: `multiplyInterestRateModels` (slug-keyed; not shared with borrow/lend).
 *
 * Fixes the "silent mock" gap on multiply detail: the IRM card renders from a
 * PRNG-derived mock (`app/lib/multiply-detail/index.ts`) with no Convex read
 * today. This query mirrors the borrow IRM shape so the client swap in Phase E
 * is a one-line reader change.
 */

import { v } from "convex/values"
import { internalMutation } from "../_generated/server"

export const upsertInterestRateModels = internalMutation({
  args: {
    rows: v.array(
      v.object({
        slug: v.string(),
        optimalUtilizationPct: v.number(),
        slopeBelowOptimalPct: v.number(),
        slopeAboveOptimalPct: v.number(),
        baseBorrowRatePct: v.number(),
        source: v.optional(v.union(v.literal("seed"), v.literal("chain"))),
        txHash: v.optional(v.string()),
      }),
    ),
  },
  handler: async (ctx, { rows }) => {
    const now = Date.now()
    for (const row of rows) {
      const rowWithTimestamp = { ...row, updatedAt: now }
      const existing = await ctx.db
        .query("multiplyInterestRateModels")
        .withIndex("by_slug", (q) => q.eq("slug", row.slug))
        .unique()
      if (existing) await ctx.db.patch(existing._id, rowWithTimestamp)
      else await ctx.db.insert("multiplyInterestRateModels", rowWithTimestamp)
    }
    return { written: rows.length }
  },
})
