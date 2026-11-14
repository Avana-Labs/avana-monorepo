/**
 * Seed mutations for the market data layer. Must stay self-contained (no app imports) so it
 * bundles cleanly; the deterministic row data is built by `app/lib/convex-seed/build-seed.ts`
 * and pushed in batches by `scripts/seed-convex.mjs`.
 *
 * Every write is an IDEMPOTENT upsert keyed by (marketId, day) / (scope, slug), and no
 * destructive "clear all" is exposed publicly, so re-running the seed is safe.
 */

import { v } from "convex/values"
import { internalMutation, internalQuery } from "./_generated/server"
import type { Id } from "./_generated/dataModel"

const marketScope = v.union(v.literal("asset"), v.literal("pool"), v.literal("lend"), v.literal("multiply"))

/**
 * Seed verification: exact counts for the small per-market tables, and only a non-empty
 * "seeded" signal for the large ones — collecting the 46k+ daily rows would blow the
 * per-query read limit. Internal-only (reached via the secret-gated `seedAdmin.getCounts`),
 * so an anonymous caller can neither invoke it nor force an unbounded scan.
 */
export const getCounts = internalQuery({
  args: {},
  handler: async (ctx) => {
    // markets + risk are one row per market (~173), so exact counts are bounded reads.
    const markets = await ctx.db.query("markets").collect()
    const [borrowRisk, lendRisk, multiplyRisk] = await Promise.all([
      ctx.db.query("borrowRiskAssessments").collect(),
      ctx.db.query("lendRiskAssessments").collect(),
      ctx.db.query("multiplyRiskAssessments").collect(),
    ])
    const risk = [...borrowRisk, ...lendRisk, ...multiplyRisk]
    // Large or heavy-per-row tables: read a single-row "seeded" signal, never collect.
    const oneAllocation = await ctx.db.query("assetPoolAllocationDaily").take(1)
    const oneContent = await ctx.db.query("borrowMarketContent").take(1)
    const oneStat = await ctx.db.query("marketDailyStats").take(1)
    const oneRevenue = await ctx.db.query("borrowRevenueDaily").take(1)
    const oneRiskWithBreakdown = risk.find((r) => r.breakdown.length > 0)
    return {
      markets: markets.length,
      assetMarkets: markets.filter((m) => m.scope === "asset").length,
      poolMarkets: markets.filter((m) => m.scope === "pool").length,
      riskAssessments: risk.length,
      riskBreakdownSeeded: oneRiskWithBreakdown !== undefined,
      allocationSeeded: oneAllocation.length > 0,
      contentSeeded: oneContent.length > 0,
      dailyStatsSeeded: oneStat.length > 0,
      revenueSeeded: oneRevenue.length > 0,
    }
  },
})

/** Upsert canonical markets by (scope, slug); returns the slug → _id map for this batch. */
export const upsertMarkets = internalMutation({
  args: {
    rows: v.array(
      v.object({
        scope: marketScope,
        slug: v.string(),
        chainId: v.number(),
        name: v.string(),
        symbol: v.string(),
        venueLabel: v.optional(v.string()),
        category: v.optional(v.union(v.literal("stable"), v.literal("crypto"), v.literal("stock"))),
        explorerUrl: v.optional(v.string()),
        reserveFactorPct: v.optional(v.number()),
        rewardsApyPct: v.optional(v.number()),
        description: v.optional(v.string()),
        iconUrl: v.optional(v.string()),
        spokeId: v.optional(v.string()),
        feeTier: v.optional(v.string()),
        maxLtvPct: v.optional(v.number()),
        priceUsd: v.optional(v.number()),
        visuals: v.optional(
          v.array(
            v.object({
              symbol: v.string(),
              shortLabel: v.string(),
              bgClassName: v.string(),
              textClassName: v.string(),
              iconUrl: v.optional(v.string()),
            }),
          ),
        ),
        resources: v.optional(v.array(v.object({ label: v.string(), href: v.string() }))),
        constituents: v.optional(v.array(v.object({ symbol: v.string(), weight: v.number() }))),
        createdAt: v.number(),
      }),
    ),
  },
  handler: async (ctx, { rows }) => {
    const idsBySlug: Record<string, Id<"markets">> = {}
    for (const row of rows) {
      const existing = await ctx.db
        .query("markets")
        .withIndex("by_scope_slug", (q) => q.eq("scope", row.scope).eq("slug", row.slug))
        .unique()
      if (existing) {
        await ctx.db.patch(existing._id, row)
        idsBySlug[row.slug] = existing._id
      } else {
        idsBySlug[row.slug] = await ctx.db.insert("markets", row)
      }
    }
    return { idsBySlug }
  },
})

/** Upsert daily market stats by (marketId, day). */
export const upsertDailyStats = internalMutation({
  args: {
    rows: v.array(
      v.object({
        marketId: v.id("markets"),
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
      }),
    ),
  },
  handler: async (ctx, { rows }) => {
    for (const row of rows) {
      const existing = await ctx.db
        .query("marketDailyStats")
        .withIndex("by_market_day", (q) => q.eq("marketId", row.marketId).eq("day", row.day))
        .unique()
      if (existing) await ctx.db.patch(existing._id, row)
      else await ctx.db.insert("marketDailyStats", row)
    }
    return { written: rows.length }
  },
})

/** Upsert latest-day allocation rows keyed by (assetId, poolId, day). */
export const upsertAllocation = internalMutation({
  args: {
    rows: v.array(
      v.object({
        assetId: v.id("markets"),
        poolId: v.id("markets"),
        day: v.string(),
        valueUsd: v.number(),
        sharePct: v.number(),
        utilizationPct: v.number(),
        borrowAprPct: v.number(),
      }),
    ),
  },
  handler: async (ctx, { rows }) => {
    for (const row of rows) {
      const sameAssetDay = await ctx.db
        .query("assetPoolAllocationDaily")
        .withIndex("by_asset_day", (q) => q.eq("assetId", row.assetId).eq("day", row.day))
        .collect()
      const existing = sameAssetDay.find((r) => r.poolId === row.poolId)
      if (existing) await ctx.db.patch(existing._id, row)
      else await ctx.db.insert("assetPoolAllocationDaily", row)
    }
    return { written: rows.length }
  },
})

const walletEventKind = v.union(
  v.literal("supply"),
  v.literal("withdraw"),
  v.literal("borrow"),
  v.literal("repay"),
  v.literal("liquidation"),
  v.literal("rewardsClaim"),
)

/** Delete a page of walletEvents (batched; loop from the caller until deleted=0). */
export const clearWalletEvents = internalMutation({
  args: { limit: v.optional(v.number()) },
  handler: async (ctx, { limit }) => {
    const rows = await ctx.db.query("walletEvents").take(limit ?? 2000)
    for (const row of rows) await ctx.db.delete(row._id)
    return { deleted: rows.length }
  },
})

/** Insert wallet activity events (engagement source). Clear first for idempotent re-seed. */
export const insertWalletEvents = internalMutation({
  args: {
    rows: v.array(
      v.object({
        marketId: v.id("markets"),
        wallet: v.string(),
        kind: walletEventKind,
        amountUsd: v.number(),
        counterparty: v.optional(v.string()),
        txHash: v.string(),
        blockNumber: v.number(),
        at: v.number(),
      }),
    ),
  },
  handler: async (ctx, { rows }) => {
    for (const row of rows) await ctx.db.insert("walletEvents", row)
    return { written: rows.length }
  },
})

/**
 * Delete stored portfolio history in bounded batches, for dropping snapshots written under an
 * older portfolio-value basis so the hero chart rebuilds on-basis. `portfolioCurrent` is left
 * alone; the next snapshot write overwrites it.
 */
export const clearPortfolioSnapshots = internalMutation({
  args: { limit: v.optional(v.number()) },
  handler: async (ctx, { limit }) => {
    const batch = Math.min(Math.max(1, limit ?? 2_000), 4_000)
    const rows = await ctx.db.query("portfolioSnapshots").take(batch)
    for (const row of rows) await ctx.db.delete(row._id)
    return { deleted: rows.length, done: rows.length < batch }
  },
})
