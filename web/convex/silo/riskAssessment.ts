/**
 * Shared Risk Premium / assessment module for the product-siloed tables
 * (`borrowRiskAssessments`, `lendRiskAssessments`, `multiplyRiskAssessments`). The three
 * product files were copies that differed only in the table name and borrow's extra `kind`.
 * Distinct from the `*RiskParameters` grid.
 */

import type { WithoutSystemFields } from "convex/server"
import { v } from "convex/values"
import type { Doc } from "../_generated/dataModel"
import { internal } from "../_generated/api"
import type { QueryCtx } from "../_generated/server"
import { internalMutation, query } from "../_generated/server"
import { kindField } from "./kindField"

const riskLevel = v.union(v.literal("low"), v.literal("moderate"), v.literal("elevated"), v.literal("high"))

const assessmentFields = {
  assessedAt: v.number(),
  premiumBps: v.number(),
  level: riskLevel,
  score: v.number(),
  headline: v.string(),
  summary: v.string(),
  breakdown: v.array(
    v.object({
      id: v.string(),
      label: v.string(),
      bps: v.number(),
      level: riskLevel,
      description: v.string(),
    }),
  ),
  metrics: v.array(
    v.object({
      id: v.string(),
      label: v.string(),
      value: v.string(),
      hint: v.optional(v.string()),
    }),
  ),
}

function shapeAssessment(row: {
  premiumBps: number
  level: "low" | "moderate" | "elevated" | "high"
  score: number
  headline: string
  summary: string
  breakdown: Array<{
    id: string
    label: string
    bps: number
    level: "low" | "moderate" | "elevated" | "high"
    description: string
  }>
  metrics: Array<{ id: string; label: string; value: string; hint?: string }>
}) {
  return {
    premiumBps: row.premiumBps,
    level: row.level,
    score: row.score,
    headline: row.headline,
    summary: row.summary,
    breakdown: row.breakdown,
    metrics: row.metrics,
  }
}

type RiskAssessmentTable = "borrowRiskAssessments" | "lendRiskAssessments" | "multiplyRiskAssessments"

export function defineRiskAssessmentModule<WithKind extends boolean = false>(
  table: RiskAssessmentTable,
  options: { withKind?: WithKind } = {},
) {
  // The tables share one document shape (borrow adds `kind`), so type the reads and writes
  // against one of them. The args validator and the schema still validate every row.
  const tableName = table as "lendRiskAssessments"
  /** Shared reader for `getRisk`, so batched detail queries compose it instead of copying it. */
  async function readRisk(ctx: QueryCtx, slug: string) {
    const row = await ctx.db
      .query(tableName)
      .withIndex("by_slug", (q) => q.eq("slug", slug))
      .unique()
    return row ? shapeAssessment(row) : null
  }

  return {
    readRisk,
    getRisk: query({
      args: { slug: v.string() },
      handler: async (ctx, { slug }) => readRisk(ctx, slug),
    }),
    upsertRiskAssessments: internalMutation({
      args: {
        rows: v.array(
          v.object({
            slug: v.string(),
            ...kindField(options.withKind ?? (false as WithKind)),
            ...assessmentFields,
          }),
        ),
      },
      handler: async (ctx, { rows }) => {
        // `kindField` is generic here, so pin the row type to the table it is written to.
        for (const row of rows as unknown as Array<WithoutSystemFields<Doc<typeof tableName>>>) {
          const existing = await ctx.db
            .query(tableName)
            .withIndex("by_slug", (q) => q.eq("slug", row.slug))
            .unique()
          if (existing) await ctx.db.patch(existing._id, row)
          else await ctx.db.insert(tableName, row)
        }
        // Keep marketSnapshotsCache in lockstep with the assessments table. `premiumBps`
        // is the ONLY field currently derived from this table by listMarketSnapshots
        // (via loadSiloedPremiumBps), so a write here without a cache rebuild would leave
        // list rows showing the old premium while the detail Risk card showed the new one.
        if (rows.length > 0) {
          await ctx.scheduler.runAfter(0, internal.markets.rebuildMarketSnapshots, {})
        }
        return { written: rows.length }
      },
    }),
  }
}
