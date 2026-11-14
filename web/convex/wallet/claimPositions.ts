/**
 * Wallet-scoped rewards / fee claim positions on the home page. Replaces
 * HOME_CLAIM_POSITIONS in app/lib/home-sim.ts:290-360.
 *
 * `breakdown` is an inline array so a single query renders the whole card
 * (symbol / amount label / usd value / visual per leg).
 */

import { v } from "convex/values"
import { internalMutation, query } from "../_generated/server"
import { requireSandboxWallet } from "../sandbox/auth"

const breakdownItem = v.object({
  symbol: v.string(),
  amountLabel: v.string(),
  amountToken: v.number(),
  usdValue: v.number(),
  visualSymbol: v.string(),
})

const rowFields = {
  claimId: v.string(),
  homePoolId: v.string(),
  marketId: v.string(),
  name: v.string(),
  subtitle: v.string(),
  totalUsd: v.number(),
  breakdown: v.array(breakdownItem),
}

export const listForWallet = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }) => {
    const authed = await requireSandboxWallet(ctx, wallet)
    const rows = await ctx.db
      .query("walletClaimPositions")
      .withIndex("by_wallet", (q) => q.eq("wallet", authed))
      .collect()
    return rows.map((row) => ({
      claimId: row.claimId,
      homePoolId: row.homePoolId,
      marketId: row.marketId,
      name: row.name,
      subtitle: row.subtitle,
      totalUsd: row.totalUsd,
      breakdown: row.breakdown,
    }))
  },
})

export const upsertForWallet = internalMutation({
  args: {
    wallet: v.string(),
    rows: v.array(v.object(rowFields)),
  },
  handler: async (ctx, { wallet, rows }) => {
    const now = Date.now()
    for (const row of rows) {
      const existing = await ctx.db
        .query("walletClaimPositions")
        .withIndex("by_wallet_claim", (q) => q.eq("wallet", wallet).eq("claimId", row.claimId))
        .unique()
      if (existing) await ctx.db.patch(existing._id, { ...row, updatedAt: now })
      else await ctx.db.insert("walletClaimPositions", { ...row, wallet, updatedAt: now })
    }
    return { written: rows.length }
  },
})

export const clearForWallet = internalMutation({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }) => {
    const rows = await ctx.db
      .query("walletClaimPositions")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect()
    for (const row of rows) await ctx.db.delete(row._id)
    return { deleted: rows.length }
  },
})
