/**
 * LP token spot prices per pool market. Public read (LP prices are on-chain data,
 * not PII); upsert is internal-only so anonymous callers can't mutate the price
 * a user's pledge preview computes against.
 */

import { v } from "convex/values"
import { internalMutation, query } from "../_generated/server"

export const getPrice = query({
  args: { slug: v.string() },
  handler: async (ctx, { slug }) => {
    const row = await ctx.db
      .query("lpTokenPrices")
      .withIndex("by_slug", (q) => q.eq("slug", slug))
      .unique()
    return row ? { slug: row.slug, priceUsd: row.priceUsd, updatedAt: row.updatedAt } : null
  },
})

export const listPrices = query({
  args: {},
  handler: async (ctx) => {
    const rows = await ctx.db.query("lpTokenPrices").collect()
    return rows.map((row) => ({ slug: row.slug, priceUsd: row.priceUsd, updatedAt: row.updatedAt }))
  },
})

export const upsertPrices = internalMutation({
  args: {
    rows: v.array(v.object({ slug: v.string(), priceUsd: v.number() })),
  },
  handler: async (ctx, { rows }) => {
    const now = Date.now()
    for (const row of rows) {
      const existing = await ctx.db
        .query("lpTokenPrices")
        .withIndex("by_slug", (q) => q.eq("slug", row.slug))
        .unique()
      if (existing) {
        await ctx.db.patch(existing._id, { priceUsd: row.priceUsd, updatedAt: now })
      } else {
        await ctx.db.insert("lpTokenPrices", { slug: row.slug, priceUsd: row.priceUsd, updatedAt: now })
      }
    }
    return { written: rows.length }
  },
})
