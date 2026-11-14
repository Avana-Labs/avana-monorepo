/**
 * Borrow product — Risk Parameters for pool/asset detail pages.
 * Table: `borrowRiskParameters` (slug-keyed; not shared with lend/multiply).
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

export async function readRiskParameters(ctx: QueryCtx, slug: string) {
  const row = await ctx.db
    .query("borrowRiskParameters")
    .withIndex("by_slug", (q) => q.eq("slug", slug))
    .unique()
  if (!row) return null
  return {
    slug: row.slug,
    kind: row.kind,
    parameters: row.parameters,
    updatedAt: row.updatedAt,
    source: row.source,
  }
}

export const getRiskParameters = query({
  args: { slug: v.string() },
  handler: async (ctx, { slug }) => readRiskParameters(ctx, slug),
})

/**
 * Batch variant: risk parameters for many slugs in ONE query round-trip. The asset
 * allocation card needs each pool's collateral factor; fetching them one slug at a
 * time was an N+1 network fan-out after the main detail batch. Lookups stay indexed
 * (by_slug), so the server cost is N cheap point reads inside a single query.
 */
export async function readRiskParametersForSlugs(ctx: QueryCtx, slugs: string[]) {
  const rows = await Promise.all(
    slugs.map((slug) =>
      ctx.db
        .query("borrowRiskParameters")
        .withIndex("by_slug", (q) => q.eq("slug", slug))
        .unique(),
    ),
  )
  return rows.filter((row) => row !== null).map((row) => ({ slug: row.slug, parameters: row.parameters }))
}

export const getRiskParametersForSlugs = query({
  args: { slugs: v.array(v.string()) },
  handler: async (ctx, { slugs }) => readRiskParametersForSlugs(ctx, slugs),
})

export const upsertRiskParameters = internalMutation({
  args: {
    rows: v.array(
      v.object({
        slug: v.string(),
        kind: v.union(v.literal("pool"), v.literal("asset")),
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
        .query("borrowRiskParameters")
        .withIndex("by_slug", (q) => q.eq("slug", row.slug))
        .unique()
      if (existing) await ctx.db.patch(existing._id, row)
      else await ctx.db.insert("borrowRiskParameters", row)
    }
    return { written: rows.length }
  },
})
