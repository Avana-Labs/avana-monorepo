/**
 * Governance "Parameter changelog" store — real parameter transitions per market.
 * Table: `parameterChanges` (product + slug keyed). Read is folded into each product's
 * `getContent` query (single round trip); this module owns the shared shape, the seed
 * upsert, and a read helper.
 */

import { v, type Infer } from "convex/values"
import { internalMutation, type QueryCtx } from "./_generated/server"

export const productValidator = v.union(v.literal("borrow"), v.literal("lend"), v.literal("multiply"))

export const changeValidator = v.object({
  id: v.string(),
  parameter: v.string(),
  previous: v.string(),
  current: v.string(),
  date: v.string(),
  source: v.string(),
  executor: v.string(),
  category: v.string(),
  href: v.optional(v.string()),
})

export type ParameterChange = Infer<typeof changeValidator>

/** Read one market's changelog (newest-first), or [] when unseeded. Used inside getContent. */
export async function readChangelog(
  ctx: QueryCtx,
  product: Infer<typeof productValidator>,
  slug: string,
): Promise<ParameterChange[]> {
  const row = await ctx.db
    .query("parameterChanges")
    .withIndex("by_market", (q) => q.eq("product", product).eq("slug", slug))
    .unique()
  return row?.changes ?? []
}

export const upsertChanges = internalMutation({
  args: {
    rows: v.array(
      v.object({
        product: productValidator,
        slug: v.string(),
        changes: v.array(changeValidator),
        updatedAt: v.number(),
      }),
    ),
  },
  handler: async (ctx, { rows }) => {
    for (const row of rows) {
      const existing = await ctx.db
        .query("parameterChanges")
        .withIndex("by_market", (q) => q.eq("product", row.product).eq("slug", row.slug))
        .unique()
      if (existing) await ctx.db.patch(existing._id, row)
      else await ctx.db.insert("parameterChanges", row)
    }
    return { written: rows.length }
  },
})
