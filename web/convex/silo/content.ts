/**
 * Shared About / FAQs / parameter-change history module for the product-siloed tables
 * (`borrowMarketContent`, `lendMarketContent`, `multiplyMarketContent`). The three product
 * files were copies that differed only in the table name, the changelog product, and
 * borrow's extra `kind`.
 */

import type { WithoutSystemFields } from "convex/server"
import { v } from "convex/values"
import type { Doc } from "../_generated/dataModel"
import type { QueryCtx } from "../_generated/server"
import { internalMutation, query } from "../_generated/server"
import { kindField } from "./kindField"
import { readChangelog } from "../parameterChanges"

const contentFields = {
  description: v.string(),
  stats: v.array(v.object({ label: v.string(), value: v.string(), href: v.optional(v.string()) })),
  history: v.array(v.object({ date: v.string(), title: v.string(), description: v.optional(v.string()) })),
  faqs: v.array(v.object({ question: v.string(), answer: v.string() })),
}

type ContentTable = "borrowMarketContent" | "lendMarketContent" | "multiplyMarketContent"

export function defineContentModule<WithKind extends boolean = false>(
  table: ContentTable,
  options: { product: "borrow" | "lend" | "multiply"; withKind?: WithKind },
) {
  // The tables share one document shape (borrow adds `kind`), so type the reads and writes
  // against one of them. The args validator and the schema still validate every row.
  const tableName = table as "lendMarketContent"
  /** Shared reader for `getContent`, so batched detail queries compose it instead of copying it. */
  async function readContent(ctx: QueryCtx, slug: string) {
    const row = await ctx.db
      .query(tableName)
      .withIndex("by_slug", (q) => q.eq("slug", slug))
      .unique()
    if (!row) return null
    return {
      description: row.description,
      stats: row.stats,
      history: row.history,
      faqs: row.faqs,
      changelog: await readChangelog(ctx, options.product, slug),
    }
  }

  return {
    readContent,
    getContent: query({
      args: { slug: v.string() },
      handler: async (ctx, { slug }) => readContent(ctx, slug),
    }),
    upsertContent: internalMutation({
      args: {
        rows: v.array(
          v.object({
            slug: v.string(),
            ...kindField(options.withKind ?? (false as WithKind)),
            ...contentFields,
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
        return { written: rows.length }
      },
    }),
  }
}
