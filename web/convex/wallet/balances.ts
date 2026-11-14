/**
 * Wallet token balances behind the dashboard "Wallet" tab, the sidebar amount pickers and
 * every action page's "Available" line. Mirrors UserAssetBalance in
 * app/lib/swap-system/contracts.ts. Every read is gated by requireSandboxWallet — a wallet's
 * holdings are NOT public data, so there are no public reads here.
 */

import { v, type Infer } from "convex/values"
import type { MutationCtx, QueryCtx } from "../_generated/server"
import { internalMutation, query } from "../_generated/server"
import { requireSandboxWallet } from "../sandbox/auth"

const sourceType = v.union(v.literal("wallet"), v.literal("position"))
const assetKind = v.union(v.literal("wallet"), v.literal("lp"), v.literal("returned-lp"))

const walletBalanceRow = v.object({
  wallet: v.string(),
  assetId: v.string(),
  amount: v.number(),
  sourceType,
  sourcePositionId: v.optional(v.id("positions")),
  assetKind: v.optional(assetKind),
  symbol: v.optional(v.string()),
  valueUsd6: v.optional(v.string()),
})

/**
 * The wallet's balances across all assets + sources. Optional `assetKind` narrows to one
 * shape ("wallet" token holdings, "lp" collateral, "returned-lp" pending withdrawal); home +
 * action pages pass it so they do not page over irrelevant rows.
 */
export const listBalances = query({
  args: { wallet: v.string(), assetKind: v.optional(assetKind) },
  handler: async (ctx, { wallet, assetKind: kindFilter }) => {
    const authed = await requireSandboxWallet(ctx, wallet)
    const rows =
      kindFilter !== undefined
        ? await ctx.db
            .query("walletBalances")
            .withIndex("by_wallet_asset_kind", (q) => q.eq("wallet", authed).eq("assetKind", kindFilter))
            .collect()
        : await ctx.db
            .query("walletBalances")
            .withIndex("by_wallet", (q) => q.eq("wallet", authed))
            .collect()
    return rows.map((row) => ({
      id: `${row.wallet}:${row.assetId}:${row.sourceType}${row.sourcePositionId ? `:${row.sourcePositionId}` : ""}`,
      walletId: row.wallet,
      assetId: row.assetId,
      amount: row.amount,
      sourceType: row.sourceType,
      sourcePositionId: row.sourcePositionId,
      assetKind: row.assetKind,
      symbol: row.symbol,
      valueUsd6: row.valueUsd6,
    }))
  },
})

/**
 * Upsert a batch of wallet balances, keyed by (wallet, assetId, sourceType, sourcePositionId).
 * Internal-only: the callers (seed writer, position upsert) are trusted, and an anonymous
 * caller must never be able to mint tokens for a wallet it does not control.
 */
export async function upsertWalletBalanceRows(ctx: MutationCtx, rows: Array<Infer<typeof walletBalanceRow>>) {
  const now = Date.now()
  for (const row of rows) {
    const existing = await ctx.db
      .query("walletBalances")
      .withIndex("by_wallet_asset", (q) => q.eq("wallet", row.wallet).eq("assetId", row.assetId))
      .collect()
    const match = existing.find(
      (candidate) => candidate.sourceType === row.sourceType && candidate.sourcePositionId === row.sourcePositionId,
    )
    if (match) {
      await ctx.db.patch(match._id, {
        amount: row.amount,
        assetKind: row.assetKind,
        symbol: row.symbol,
        valueUsd6: row.valueUsd6,
        updatedAt: now,
      })
    } else {
      await ctx.db.insert("walletBalances", { ...row, updatedAt: now })
    }
  }
  return { written: rows.length }
}

export async function readWalletLiquidBalance(ctx: QueryCtx | MutationCtx, wallet: string, assetId: string) {
  return ctx.db
    .query("walletLiquidBalances")
    .withIndex("by_wallet_asset", (q) => q.eq("wallet", wallet).eq("assetId", assetId))
    .first()
}

export async function upsertLiquidWalletBalance(
  ctx: MutationCtx,
  row: { wallet: string; assetId: string; symbol: string; amount: number; valueUsd: number; updatedAt?: number },
) {
  const now = row.updatedAt ?? Date.now()
  const existing = await readWalletLiquidBalance(ctx, row.wallet, row.assetId)
  const liquid = {
    wallet: row.wallet,
    assetId: row.assetId,
    symbol: row.symbol,
    amount: Math.max(0, row.amount),
    valueUsd: Math.max(0, row.valueUsd),
    state: "available" as const,
    updatedAt: now,
  }
  if (existing) await ctx.db.patch(existing._id, liquid)
  else if (liquid.amount > 0 || liquid.valueUsd > 0) await ctx.db.insert("walletLiquidBalances", liquid)

  await upsertWalletBalanceRows(ctx, [
    {
      wallet: row.wallet,
      assetId: row.assetId,
      amount: liquid.amount,
      sourceType: "wallet",
      assetKind: "wallet",
      symbol: row.symbol,
      valueUsd6: String(Math.round(liquid.valueUsd * 1_000_000)),
    },
  ])
}

export function liquidBalanceView(row: {
  wallet: string
  assetId: string
  symbol: string
  amount: number
  valueUsd: number
  updatedAt: number
}) {
  return {
    ...row,
    assetSlug: row.assetId,
    priceUsd: row.amount > 0 ? row.valueUsd / row.amount : 0,
  }
}

export const upsertBalances = internalMutation({
  args: {
    rows: v.array(walletBalanceRow),
  },
  handler: async (ctx, { rows }) => upsertWalletBalanceRows(ctx, rows),
})

/** Delete a wallet's balance rows, for a dev reseed or a closing position — stale $0 rows are
 *  a rendering foot-gun. */
export const deleteBalances = internalMutation({
  args: { wallet: v.string(), positionId: v.optional(v.id("positions")) },
  handler: async (ctx, { wallet, positionId }) => {
    const rows = await ctx.db
      .query("walletBalances")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect()
    let deleted = 0
    for (const row of rows) {
      if (positionId !== undefined && row.sourcePositionId !== positionId) continue
      await ctx.db.delete(row._id)
      deleted += 1
    }
    return { deleted }
  },
})
