/**
 * Shared Liquidation Risk KPI module for the product-siloed tables
 * (`borrowLiquidationDaily`, `multiplyLiquidationDaily`). The two product files were copies
 * that differed only in the table name.
 */

import { v } from "convex/values"
import type { QueryCtx } from "../_generated/server"
import { internalMutation, query } from "../_generated/server"
import { formatCompactUsdStatic } from "../../app/lib/format-usd-static"

type Totals = {
  liquidationsCount: number
  collateralSeizedUsd: number
  debtRepaidUsd: number
  liquidationBonusUsd: number
  collateralAtRiskUsd: number
  walletsAtRisk: number
  walletsEligibleForLiquidation: number
  badDebtUsd: number
  walletsWithBadDebt: number
}

function formatCount(value: number): string {
  const abs = Math.abs(value)
  if (abs >= 1_000_000) return `${(value / 1_000_000).toFixed(2)}M`
  if (abs >= 1_000) return `${(value / 1_000).toFixed(2)}K`
  return String(Math.round(value))
}

function foldStats(latest: Totals, previous?: Totals | null) {
  const make = (id: string, label: string, curr: number, prev: number | undefined, format: "usd" | "number") => {
    const deltaValue = prev === undefined ? 0 : curr - prev
    const abs = Math.abs(deltaValue)
    return {
      id,
      label,
      value: format === "usd" ? formatCompactUsdStatic(curr) : formatCount(curr),
      deltaValue,
      deltaLabel: format === "usd" ? formatCompactUsdStatic(abs) : formatCount(abs),
      goodDirection: "down" as const,
      format,
    }
  }
  return [
    make("liquidations", "Liquidations (24h)", latest.liquidationsCount, previous?.liquidationsCount, "number"),
    make(
      "collateralSeized",
      "Collateral seized (24h)",
      latest.collateralSeizedUsd,
      previous?.collateralSeizedUsd,
      "usd",
    ),
    make("debtRepaid", "Debt repaid (24h)", latest.debtRepaidUsd, previous?.debtRepaidUsd, "usd"),
    make("collateralAtRisk", "Collateral at risk", latest.collateralAtRiskUsd, previous?.collateralAtRiskUsd, "usd"),
    make("walletsAtRisk", "Wallets at risk", latest.walletsAtRisk, previous?.walletsAtRisk, "number"),
    make("badDebt", "Bad debt", latest.badDebtUsd, previous?.badDebtUsd, "usd"),
  ]
}

type LiquidationDailyTable = "borrowLiquidationDaily" | "multiplyLiquidationDaily"

export function defineLiquidationRiskModule(table: LiquidationDailyTable) {
  // Both tables share one document shape, so type the reads and writes against one of them.
  // The args validator and the schema still validate every row.
  const tableName = table as "multiplyLiquidationDaily"
  /** Shared reader for `getLiquidationRisk`, so batched detail queries compose it instead of copying it. */
  async function readLiquidationRisk(ctx: QueryCtx, slug: string) {
    const rows = await ctx.db
      .query(tableName)
      .withIndex("by_slug_day", (q) => q.eq("slug", slug))
      .order("desc")
      .take(2)
    const latest = rows[0]
    if (!latest) return null
    const previous = rows[1]
    return {
      slug,
      day: latest.day,
      stats: foldStats(latest, previous ?? null),
    }
  }

  return {
    readLiquidationRisk,
    getLiquidationRisk: query({
      args: { slug: v.string() },
      handler: async (ctx, { slug }) => readLiquidationRisk(ctx, slug),
    }),

    upsertLiquidationDaily: internalMutation({
      args: {
        rows: v.array(
          v.object({
            slug: v.string(),
            day: v.string(),
            liquidationsCount: v.number(),
            collateralSeizedUsd: v.number(),
            debtRepaidUsd: v.number(),
            liquidationBonusUsd: v.number(),
            collateralAtRiskUsd: v.number(),
            walletsAtRisk: v.number(),
            walletsEligibleForLiquidation: v.number(),
            badDebtUsd: v.number(),
            walletsWithBadDebt: v.number(),
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
