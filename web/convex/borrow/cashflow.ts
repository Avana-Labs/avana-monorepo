/**
 * Borrow product — Cashflow (pool + asset).
 * Table: `borrowRevenueDaily` (slug-keyed; not shared with lend/multiply).
 */

import { v } from "convex/values"
import { internalMutation, query } from "../_generated/server"
import {
  buildCashflowBreakdown,
  buildRevenueTrend,
  loadSiloedRevenueDaily,
  rollupMonthlyRevenue,
} from "../cashflowHelpers"

const revenueFields = {
  day: v.string(),
  interestFromBorrowersUsd: v.number(),
  interestToSuppliersUsd: v.number(),
  reserveTakeUsd: v.number(),
  rewardsDistributedUsd: v.number(),
  swapFeesUsd: v.number(),
}

export const getRevenueForAsset = query({
  args: { slug: v.string() },
  handler: async (ctx, { slug }) => {
    const rows = await loadSiloedRevenueDaily(ctx, "borrowRevenueDaily", slug)
    if (rows.length === 0) return null
    return buildRevenueTrend(rollupMonthlyRevenue(rows), slug)
  },
})

export const getBreakdownForAsset = query({
  args: { slug: v.string() },
  handler: async (ctx, { slug }) => {
    const rows = await loadSiloedRevenueDaily(ctx, "borrowRevenueDaily", slug)
    if (rows.length === 0) return null
    return buildCashflowBreakdown(rollupMonthlyRevenue(rows), slug, "asset")
  },
})

export const getBreakdownForPool = query({
  args: { slug: v.string() },
  handler: async (ctx, { slug }) => {
    const rows = await loadSiloedRevenueDaily(ctx, "borrowRevenueDaily", slug)
    if (rows.length === 0) return null
    return buildCashflowBreakdown(rollupMonthlyRevenue(rows), slug, "pool")
  },
})

export const upsertRevenueDaily = internalMutation({
  args: {
    rows: v.array(
      v.object({
        slug: v.string(),
        kind: v.union(v.literal("pool"), v.literal("asset")),
        ...revenueFields,
      }),
    ),
  },
  handler: async (ctx, { rows }) => {
    for (const row of rows) {
      const existing = await ctx.db
        .query("borrowRevenueDaily")
        .withIndex("by_slug_day", (q) => q.eq("slug", row.slug).eq("day", row.day))
        .unique()
      if (existing) await ctx.db.patch(existing._id, row)
      else await ctx.db.insert("borrowRevenueDaily", row)
    }
    return { written: rows.length }
  },
})
