/**
 * Shared Cashflow module for the product-siloed `lendRevenueDaily` and
 * `multiplyRevenueDaily` tables. The two product files were copies that differed only in the
 * table name and the breakdown scope. Borrow's module has its own logic and does not use this.
 */

import { v } from "convex/values"
import { internalMutation, query } from "../_generated/server"
import { buildCashflowBreakdown, loadSiloedRevenueDaily, rollupMonthlyRevenue } from "../cashflowHelpers"

const revenueFields = {
  day: v.string(),
  interestFromBorrowersUsd: v.number(),
  interestToSuppliersUsd: v.number(),
  reserveTakeUsd: v.number(),
  rewardsDistributedUsd: v.number(),
  swapFeesUsd: v.number(),
}

type RevenueDailyTable = "lendRevenueDaily" | "multiplyRevenueDaily"

export function defineCashflowModule(table: RevenueDailyTable, options: { scope: "lend" | "multiply" }) {
  // Both tables share one document shape, so type the writes against one of them. The args
  // validator and the schema still validate every row.
  const tableName = table as "lendRevenueDaily"
  return {
    getBreakdown: query({
      args: { slug: v.string() },
      handler: async (ctx, { slug }) => {
        const rows = await loadSiloedRevenueDaily(ctx, table, slug)
        if (rows.length === 0) return null
        return buildCashflowBreakdown(rollupMonthlyRevenue(rows), slug, options.scope)
      },
    }),
    upsertRevenueDaily: internalMutation({
      args: {
        rows: v.array(
          v.object({
            slug: v.string(),
            ...revenueFields,
          }),
        ),
      },
      handler: async (ctx, { rows }) => {
        for (const row of rows) {
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
