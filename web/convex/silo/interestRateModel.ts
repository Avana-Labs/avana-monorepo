/**
 * Shared Interest Rate Model module for the product-siloed `borrowInterestRateModels` and
 * `lendInterestRateModels` tables. The two product files were copies that differed only in
 * the tables they read and the legacy `markets` scope. Multiply's module has its own logic
 * and does not use this.
 */

import { v } from "convex/values"
import type { QueryCtx } from "../_generated/server"
import { internalMutation, query } from "../_generated/server"

const PRODUCT_TABLES = {
  borrow: {
    irm: "borrowInterestRateModels",
    dailyStats: "borrowDailyStats",
    riskAssessments: "borrowRiskAssessments",
    legacyScope: "asset",
  },
  lend: {
    irm: "lendInterestRateModels",
    dailyStats: "lendDailyStats",
    riskAssessments: "lendRiskAssessments",
    legacyScope: "lend",
  },
} as const

export function defineInterestRateModelModule(product: keyof typeof PRODUCT_TABLES) {
  const tables = PRODUCT_TABLES[product]
  // Each table pair shares one document shape (borrow adds `kind` to stats/assessments), so
  // type the reads and writes against one of them. The args validator and the schema still
  // validate every row.
  const irmTable = tables.irm as "lendInterestRateModels"
  const dailyStatsTable = tables.dailyStats as "lendDailyStats"
  const riskAssessmentsTable = tables.riskAssessments as "lendRiskAssessments"
  /** Shared reader for `getInterestRateModel`, so batched detail queries compose it instead of copying it. */
  async function readInterestRateModel(ctx: QueryCtx, slug: string) {
    const row = await ctx.db
      .query(irmTable)
      .withIndex("by_slug", (q) => q.eq("slug", slug))
      .unique()
    if (!row) return null

    // Prefer product-siloed daily stats; fall back to legacy marketDailyStats.
    const siloed = await ctx.db
      .query(dailyStatsTable)
      .withIndex("by_slug_day", (q) => q.eq("slug", slug))
      .order("desc")
      .first()
    let utilizationPct = siloed?.utilizationPct ?? 0
    let baseBorrowAprPct = siloed?.borrowAprPct ?? 0
    if (!siloed) {
      const market = await ctx.db
        .query("markets")
        .withIndex("by_scope_slug", (q) => q.eq("scope", tables.legacyScope).eq("slug", slug))
        .unique()
      if (market) {
        const latest = await ctx.db
          .query("marketDailyStats")
          .withIndex("by_market_day", (q) => q.eq("marketId", market._id))
          .order("desc")
          .first()
        if (latest) {
          utilizationPct = latest.utilizationPct
          baseBorrowAprPct = latest.borrowAprPct
        }
      }
    }

    // The daily-stat APR is the BASE rate only. The rate the engine actually charges — and
    // what the borrow/lend lists and dashboard display — is base + risk premium. Add the
    // per-market risk premium here so the detail IRM headline uses the same "base + risk
    // premium" source as every other surface (C2), instead of the base-only walked value.
    const assessment = await ctx.db
      .query(riskAssessmentsTable)
      .withIndex("by_slug", (q) => q.eq("slug", slug))
      .first()
    const riskPremiumPct = assessment ? assessment.premiumBps / 100 : 0
    const borrowAprPct = baseBorrowAprPct + riskPremiumPct

    return {
      slug: row.slug,
      optimalUtilizationPct: row.optimalUtilizationPct,
      slopeBelowOptimalPct: row.slopeBelowOptimalPct,
      slopeAboveOptimalPct: row.slopeAboveOptimalPct,
      baseBorrowRatePct: row.baseBorrowRatePct,
      utilizationPct,
      borrowAprPct,
      updatedAt: row.updatedAt,
      source: row.source,
    }
  }

  return {
    readInterestRateModel,
    getInterestRateModel: query({
      args: { slug: v.string() },
      handler: async (ctx, { slug }) => readInterestRateModel(ctx, slug),
    }),
    upsertInterestRateModels: internalMutation({
      args: {
        rows: v.array(
          v.object({
            slug: v.string(),
            optimalUtilizationPct: v.number(),
            slopeBelowOptimalPct: v.number(),
            slopeAboveOptimalPct: v.number(),
            baseBorrowRatePct: v.number(),
            updatedAt: v.number(),
            source: v.optional(v.union(v.literal("seed"), v.literal("chain"))),
            txHash: v.optional(v.string()),
          }),
        ),
      },
      handler: async (ctx, { rows }) => {
        for (const row of rows) {
          const existing = await ctx.db
            .query(irmTable)
            .withIndex("by_slug", (q) => q.eq("slug", row.slug))
            .unique()
          if (existing) await ctx.db.patch(existing._id, row)
          else await ctx.db.insert(irmTable, row)
        }
        return { written: rows.length }
      },
    }),
  }
}
