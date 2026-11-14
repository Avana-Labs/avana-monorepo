/**
 * Wallet-scoped open debts. Feeds the home page debts table + the action-page
 * repay picker. Replaces the HOME_INITIAL_DEBTS mock injection at
 * app/lib/borrow-system/mock.ts:365-373 which leaked 1200 USDC + 800 USDT into
 * every authenticated wallet's session.
 *
 * Reads are wallet-scoped (requireSandboxWallet). Upsert is internal-only.
 * Test wallet ("test-wallet-000") is seeded with the mock's initial debts so
 * the home page still renders populated cards in dev.
 */

import { v } from "convex/values"
import { internalMutation, query } from "../_generated/server"
import { requireSandboxWallet } from "../sandbox/auth"

const rowFields = {
  homePoolId: v.string(),
  marketId: v.string(),
  debtAssetId: v.string(),
  amountUsd: v.number(),
}

export const listForWallet = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }) => {
    const authed = await requireSandboxWallet(ctx, wallet)
    const rows = await ctx.db
      .query("walletDebts")
      .withIndex("by_wallet", (q) => q.eq("wallet", authed))
      .collect()
    return rows.map((row) => ({
      homePoolId: row.homePoolId,
      marketId: row.marketId,
      debtAssetId: row.debtAssetId,
      amountUsd: row.amountUsd,
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
        .query("walletDebts")
        .withIndex("by_wallet_home_pool", (q) => q.eq("wallet", wallet).eq("homePoolId", row.homePoolId))
        .unique()
      if (existing) await ctx.db.patch(existing._id, { ...row, updatedAt: now })
      else await ctx.db.insert("walletDebts", { ...row, wallet, updatedAt: now })
    }
    return { written: rows.length }
  },
})

export const clearForWallet = internalMutation({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }) => {
    const rows = await ctx.db
      .query("walletDebts")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect()
    for (const row of rows) await ctx.db.delete(row._id)
    return { deleted: rows.length }
  },
})
