/**
 * Wallet-scoped home page collateral positions — the "ETH/USDC $4200 pledged"
 * cards on the home page and the action-page sidebar HomeCollateralPool.
 *
 * Reads are wallet-scoped (requireSandboxWallet). Upsert is internal-only
 * (seed writer + position-close mirror). Test wallet convention: rows are
 * seeded for "test-wallet-000" so dev sessions render populated cards without
 * a real wallet connection.
 */

import { v } from "convex/values"
import { internalMutation, query } from "../_generated/server"
import { requireSandboxWallet } from "../sandbox/auth"

const rowFields = {
  homePoolId: v.string(),
  marketId: v.string(),
  name: v.string(),
  venueLabel: v.string(),
  category: v.string(),
  collateralUsd: v.number(),
  maxLtvPct: v.number(),
  borrowPowerUsd: v.number(),
  liquidationUsd: v.number(),
  pairAprPct: v.number(),
}

export const listForWallet = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }) => {
    const authed = await requireSandboxWallet(ctx, wallet)
    const rows = await ctx.db
      .query("walletCollateralPositions")
      .withIndex("by_wallet", (q) => q.eq("wallet", authed))
      .collect()
    return rows.map((row) => ({
      homePoolId: row.homePoolId,
      marketId: row.marketId,
      name: row.name,
      venueLabel: row.venueLabel,
      category: row.category,
      collateralUsd: row.collateralUsd,
      maxLtvPct: row.maxLtvPct,
      borrowPowerUsd: row.borrowPowerUsd,
      liquidationUsd: row.liquidationUsd,
      pairAprPct: row.pairAprPct,
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
        .query("walletCollateralPositions")
        .withIndex("by_wallet_home_pool", (q) => q.eq("wallet", wallet).eq("homePoolId", row.homePoolId))
        .unique()
      if (existing) await ctx.db.patch(existing._id, { ...row, updatedAt: now })
      else await ctx.db.insert("walletCollateralPositions", { ...row, wallet, updatedAt: now })
    }
    return { written: rows.length }
  },
})

/** Delete a wallet's collateral position rows (used when reseeding). */
export const clearForWallet = internalMutation({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }) => {
    const rows = await ctx.db
      .query("walletCollateralPositions")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect()
    for (const row of rows) await ctx.db.delete(row._id)
    return { deleted: rows.length }
  },
})
