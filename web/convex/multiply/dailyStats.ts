/**
 * Multiply product — daily market stats.
 * Table: `multiplyDailyStats` (slug-keyed; not shared with borrow/lend).
 */

import { v } from "convex/values"
import { internalMutation, query } from "../_generated/server"

const dailyStatFields = {
  day: v.string(),
  suppliedUsd: v.number(),
  borrowedUsd: v.number(),
  utilizationPct: v.number(),
  supplyApyPct: v.number(),
  borrowAprPct: v.number(),
  tvlUsd: v.number(),
  volumeUsd: v.number(),
  feesUsd: v.number(),
  priceUsd: v.optional(v.number()),
  supplyCapUsd: v.optional(v.number()),
  borrowCapUsd: v.optional(v.number()),
}

/**
 * Historical utilization (borrowed ÷ supplied) for a multiply market over the last
 * 12 months. Same shape as convex/markets.ts getHistoricalUtilization but scoped
 * to multiplyDailyStats — feeds the multiply detail's historicalUtilization chart
 * so it stops falling back to the mock series.
 */
// Series readers return the trailing year, as the doc comments promise; the table gains a row per
// market per day, so an unbounded read grew every payload forever (405 days per market on 2026-09-22).
function oneYearAgoDay() {
  return new Date(Date.now() - 365 * 86_400_000).toISOString().slice(0, 10)
}

export const getHistoricalUtilization = query({
  args: { slug: v.string() },
  handler: async (ctx, { slug }) => {
    const rows = await ctx.db
      .query("multiplyDailyStats")
      .withIndex("by_slug_day", (q) => q.eq("slug", slug).gte("day", oneYearAgoDay()))
      .order("asc")
      .collect()
    if (rows.length === 0) return null
    return {
      id: `multiply:${slug}:historical-utilization`,
      label: "Utilization",
      points: rows.map((r) => ({ t: r.day, v: r.utilizationPct })),
    }
  },
})

/**
 * Supply, borrow and utilization series for the multiply detail's SupplyBorrowCard.
 * Same triple-series shape as convex/markets.ts getSupplyBorrow for asset scope.
 */
export const getSupplyBorrow = query({
  args: { slug: v.string() },
  handler: async (ctx, { slug }) => {
    const rows = await ctx.db
      .query("multiplyDailyStats")
      .withIndex("by_slug_day", (q) => q.eq("slug", slug).gte("day", oneYearAgoDay()))
      .order("asc")
      .collect()
    if (rows.length === 0) return null
    const prefix = `multiply:${slug}`
    return {
      supplied: {
        id: `${prefix}:sb:supplied`,
        label: "Supplied",
        points: rows.map((r) => ({ t: r.day, v: r.suppliedUsd })),
      },
      borrowed: {
        id: `${prefix}:sb:borrowed`,
        label: "Borrowed",
        points: rows.map((r) => ({ t: r.day, v: r.borrowedUsd })),
      },
      utilization: {
        id: `${prefix}:sb:utilization`,
        label: "Utilization",
        points: rows.map((r) => ({ t: r.day, v: r.utilizationPct })),
      },
    }
  },
})

export const getLatestStats = query({
  args: { slug: v.string() },
  handler: async (ctx, { slug }) => {
    const row = await ctx.db
      .query("multiplyDailyStats")
      .withIndex("by_slug_day", (q) => q.eq("slug", slug))
      .order("desc")
      .first()
    if (!row) return null
    return {
      slug: row.slug,
      day: row.day,
      suppliedUsd: row.suppliedUsd,
      borrowedUsd: row.borrowedUsd,
      utilizationPct: row.utilizationPct,
      supplyApyPct: row.supplyApyPct,
      borrowAprPct: row.borrowAprPct,
      tvlUsd: row.tvlUsd,
      volumeUsd: row.volumeUsd,
      feesUsd: row.feesUsd,
      priceUsd: row.priceUsd,
      supplyCapUsd: row.supplyCapUsd,
      borrowCapUsd: row.borrowCapUsd,
    }
  },
})

export const upsertDailyStats = internalMutation({
  args: {
    rows: v.array(
      v.object({
        slug: v.string(),
        ...dailyStatFields,
      }),
    ),
  },
  handler: async (ctx, { rows }) => {
    for (const row of rows) {
      const existing = await ctx.db
        .query("multiplyDailyStats")
        .withIndex("by_slug_day", (q) => q.eq("slug", row.slug).eq("day", row.day))
        .unique()
      if (existing) await ctx.db.patch(existing._id, row)
      else await ctx.db.insert("multiplyDailyStats", row)
    }
    return { written: rows.length }
  },
})
