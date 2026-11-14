/**
 * Pure helpers for folding market liquidation daily rows into UI stats with
 * day-over-day deltas. Shared by Convex product queries and unit tests.
 */

import { formatCompactUsdStatic } from "@/app/lib/format-usd-static"

type LiquidationDailyTotals = {
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

export type LiquidationRiskStat = {
  id: string
  label: string
  value: string
  /** Absolute day-over-day change (latest − previous). Sign drives ▲/▼. */
  deltaValue: number
  /** Pre-formatted absolute delta label without sign (UI adds ▲/▼). */
  deltaLabel: string
  /** For risk metrics, down is good. */
  goodDirection: "up" | "down"
  format: "usd" | "number"
}

function formatCount(value: number): string {
  const abs = Math.abs(value)
  if (abs >= 1_000_000) return `${(value / 1_000_000).toFixed(2)}M`
  if (abs >= 1_000) return `${(value / 1_000).toFixed(2)}K`
  return String(Math.round(value))
}

function formatDelta(value: number, format: "usd" | "number"): string {
  const abs = Math.abs(value)
  if (format === "usd") return formatCompactUsdStatic(abs).replace(/^\$/, "")
  return formatCount(abs)
}

function stat(
  id: string,
  label: string,
  latest: number,
  previous: number | undefined,
  format: "usd" | "number",
): LiquidationRiskStat {
  const deltaValue = previous === undefined ? 0 : latest - previous
  return {
    id,
    label,
    value: format === "usd" ? formatCompactUsdStatic(latest) : formatCount(latest),
    deltaValue,
    deltaLabel: format === "usd" ? `$${formatDelta(deltaValue, format)}` : formatDelta(deltaValue, format),
    goodDirection: "down",
    format,
  }
}

/** Fold latest vs previous daily liquidation totals into the 6 UI KPIs. */
export function foldLiquidationRiskStats(
  latest: LiquidationDailyTotals,
  previous?: LiquidationDailyTotals | null,
): LiquidationRiskStat[] {
  return [
    stat("liquidations", "Liquidations (24h)", latest.liquidationsCount, previous?.liquidationsCount, "number"),
    stat(
      "collateralSeized",
      "Collateral seized (24h)",
      latest.collateralSeizedUsd,
      previous?.collateralSeizedUsd,
      "usd",
    ),
    stat("debtRepaid", "Debt repaid (24h)", latest.debtRepaidUsd, previous?.debtRepaidUsd, "usd"),
    stat("collateralAtRisk", "Collateral at risk", latest.collateralAtRiskUsd, previous?.collateralAtRiskUsd, "usd"),
    stat("walletsAtRisk", "Wallets at risk", latest.walletsAtRisk, previous?.walletsAtRisk, "number"),
    stat("badDebt", "Bad debt", latest.badDebtUsd, previous?.badDebtUsd, "usd"),
  ]
}
