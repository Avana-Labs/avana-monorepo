/**
 * Multiply per-token parameters — supply/borrow APY, availability, CF, LT.
 * Replaces the six MULTIPLY_TOKEN_* / MULTIPLY_COLLATERAL_FACTORS /
 * MULTIPLY_LIQUIDATION_THRESHOLDS constants in `app/lib/multiply-sim.ts`.
 */

import { v } from "convex/values"
import { internalMutation, query } from "../_generated/server"

const tokenRow = {
  symbol: v.string(),
  supplyApyPct: v.number(),
  borrowAprPct: v.number(),
  availableUsd: v.number(),
  collateralFactorPct: v.number(),
  liquidationThresholdPct: v.number(),
  iconUrl: v.string(),
}

export const listTokens = query({
  args: {},
  handler: async (ctx) => {
    const rows = await ctx.db.query("multiplyTokenParameters").collect()
    return rows.map(({ _id: _mid, _creationTime: _mct, updatedAt: _mua, ...rest }) => rest)
  },
})

export const getToken = query({
  args: { symbol: v.string() },
  handler: async (ctx, { symbol }) => {
    const row = await ctx.db
      .query("multiplyTokenParameters")
      .withIndex("by_symbol", (q) => q.eq("symbol", symbol))
      .unique()
    if (!row) return null
    const { _id: _mid, _creationTime: _mct, updatedAt: _mua, ...rest } = row
    return rest
  },
})

export const upsertTokens = internalMutation({
  args: { rows: v.array(v.object(tokenRow)) },
  handler: async (ctx, { rows }) => {
    const now = Date.now()
    for (const row of rows) {
      const existing = await ctx.db
        .query("multiplyTokenParameters")
        .withIndex("by_symbol", (q) => q.eq("symbol", row.symbol))
        .unique()
      if (existing) await ctx.db.patch(existing._id, { ...row, updatedAt: now })
      else await ctx.db.insert("multiplyTokenParameters", { ...row, updatedAt: now })
    }
    return { written: rows.length }
  },
})
