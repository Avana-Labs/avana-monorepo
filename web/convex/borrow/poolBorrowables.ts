/**
 * Borrow product — Assets You Can Borrow edges for pool detail pages.
 * Table: `borrowPoolBorrowables` (not shared with lend/multiply).
 */

import { v } from "convex/values"
import type { QueryCtx } from "../_generated/server"
import { internalMutation, query } from "../_generated/server"

export async function readPoolBorrowables(ctx: QueryCtx, poolSlug: string) {
  const rows = await ctx.db
    .query("borrowPoolBorrowables")
    .withIndex("by_pool", (q) => q.eq("poolSlug", poolSlug))
    .collect()
  return rows
    .map((row) => ({
      id: row.assetSlug,
      name: row.name,
      symbol: row.symbol,
      borrowAprPct: row.borrowAprPct,
    }))
    .sort((a, b) => a.name.localeCompare(b.name))
}

export const getPoolBorrowables = query({
  args: { poolSlug: v.string() },
  handler: async (ctx, { poolSlug }) => readPoolBorrowables(ctx, poolSlug),
})

export const upsertPoolBorrowables = internalMutation({
  args: {
    rows: v.array(
      v.object({
        poolSlug: v.string(),
        assetSlug: v.string(),
        name: v.string(),
        symbol: v.string(),
        borrowAprPct: v.number(),
      }),
    ),
  },
  handler: async (ctx, { rows }) => {
    // Replace-by-pool: delete existing edges for touched pools, then insert.
    const pools = [...new Set(rows.map((row) => row.poolSlug))]
    for (const poolSlug of pools) {
      const existing = await ctx.db
        .query("borrowPoolBorrowables")
        .withIndex("by_pool", (q) => q.eq("poolSlug", poolSlug))
        .collect()
      for (const row of existing) await ctx.db.delete(row._id)
    }
    for (const row of rows) await ctx.db.insert("borrowPoolBorrowables", row)
    return { written: rows.length }
  },
})
