/**
 * Shared Risk Parameters module for the product-siloed `lendRiskParameters` and
 * `multiplyRiskParameters` tables. The two product files were copies that differed only in
 * the table name. Borrow's module has its own logic and does not use this.
 */

import { v } from "convex/values"
import type { QueryCtx } from "../_generated/server"
import { internalMutation, query } from "../_generated/server"

const parameterRow = v.object({
  id: v.string(),
  label: v.string(),
  value: v.string(),
  description: v.optional(v.string()),
})

type RiskParametersTable = "lendRiskParameters" | "multiplyRiskParameters"

export function defineRiskParametersModule(table: RiskParametersTable) {
  // Both tables share one document shape, so type the reads and writes against one of them.
  // The args validator and the schema still validate every row.
  const tableName = table as "lendRiskParameters"
  /** Shared reader for `getRiskParameters`, so batched detail queries compose it instead of copying it. */
  async function readRiskParameters(ctx: QueryCtx, slug: string) {
    const row = await ctx.db
      .query(tableName)
      .withIndex("by_slug", (q) => q.eq("slug", slug))
      .unique()
    if (!row) return null
    return {
      slug: row.slug,
      parameters: row.parameters,
      updatedAt: row.updatedAt,
      source: row.source,
    }
  }

  return {
    readRiskParameters,
    getRiskParameters: query({
      args: { slug: v.string() },
      handler: async (ctx, { slug }) => readRiskParameters(ctx, slug),
    }),
    upsertRiskParameters: internalMutation({
      args: {
        rows: v.array(
          v.object({
            slug: v.string(),
            parameters: v.array(parameterRow),
            updatedAt: v.number(),
            source: v.optional(v.union(v.literal("seed"), v.literal("chain"))),
            txHash: v.optional(v.string()),
          }),
        ),
      },
      handler: async (ctx, { rows }) => {
        for (const row of rows) {
          const existing = await ctx.db
            .query(tableName)
            .withIndex("by_slug", (q) => q.eq("slug", row.slug))
            .unique()
          if (existing) await ctx.db.patch(existing._id, row)
          else await ctx.db.insert(tableName, row)
        }
        return { written: rows.length }
      },
    }),
  }
}
