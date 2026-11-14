/**
 * Shared daily market stats module for the product-siloed `borrowDailyStats` and
 * `lendDailyStats` tables. The two product files were copies that differed only in the table
 * name and borrow's extra `kind` (also returned by `getLatestStats`, via `identity`).
 * Multiply's module has its own logic and does not use this.
 */

import { v } from "convex/values"
import type { WithoutSystemFields } from "convex/server"
import type { Doc } from "../_generated/dataModel"
import { internalMutation, query } from "../_generated/server"
import { kindField } from "./kindField"

const dailyStatFields = {
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
}

type DailyStatsTable = "borrowDailyStats" | "lendDailyStats"

export function defineDailyStatsModule<
  T extends DailyStatsTable,
  Identity extends object,
  WithKind extends boolean = false,
>(table: T, options: { withKind?: WithKind; identity: (row: Doc<T>) => Identity }) {
  // The tables share one document shape (borrow adds `kind`), so type the reads and writes
  // against one of them. The args validator and the schema still validate every row;
  // `identity` sees the row as its real table type.
  const tableName = table as DailyStatsTable as "lendDailyStats"
  return {
    getLatestStats: query({
      args: { slug: v.string() },
      handler: async (ctx, { slug }) => {
        const row = await ctx.db
          .query(tableName)
          .withIndex("by_slug_day", (q) => q.eq("slug", slug))
          .order("desc")
          .first()
        if (!row) return null
        return {
          slug: row.slug,
          ...options.identity(row as unknown as Doc<T>),
          day: row.day,
          suppliedUsd: row.suppliedUsd,
          borrowedUsd: row.borrowedUsd,
          utilizationPct: row.utilizationPct,
          supplyApyPct: row.supplyApyPct,
          borrowAprPct: row.borrowAprPct,
          tvlUsd: row.tvlUsd,
          volumeUsd: row.volumeUsd,
          feesUsd: row.feesUsd,
          priceUsd: row.priceUsd,
          supplyCapUsd: row.supplyCapUsd,
          borrowCapUsd: row.borrowCapUsd,
        }
      },
    }),
    upsertDailyStats: internalMutation({
      args: {
        rows: v.array(
          v.object({
            slug: v.string(),
            ...kindField(options.withKind ?? (false as WithKind)),
            ...dailyStatFields,
          }),
        ),
      },
      handler: async (ctx, { rows }) => {
        // `kindField` is generic here, so pin the row type to the table it is written to.
        for (const row of rows as unknown as Array<WithoutSystemFields<Doc<typeof tableName>>>) {
          const existing = await ctx.db
            .query(tableName)
            .withIndex("by_slug_day", (q) => q.eq("slug", row.slug).eq("day", row.day))
            .unique()
          if (existing) await ctx.db.patch(existing._id, row)
          else await ctx.db.insert(tableName, row)
        }
        return { written: rows.length }
      },
    }),
  }
}
