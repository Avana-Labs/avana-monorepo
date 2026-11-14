/**
 * Shared cashflow monthly rollup + CashflowCard shaping used by product silos
 * and the legacy `cashflow.ts` dual-read path.
 */

import type { QueryCtx } from "./_generated/server"
import { formatCompactUsdStatic } from "../app/lib/format-usd-static"

export const CASHFLOW_MONTHS = 12

export type RevenueDailyAmounts = {
  day: string
  interestFromBorrowersUsd: number
  interestToSuppliersUsd: number
  reserveTakeUsd: number
  rewardsDistributedUsd: number
  swapFeesUsd: number
}

export type MonthlyRevenueBucket = {
  month: string
  interestFromBorrowersUsd: number
  interestToSuppliersUsd: number
  reserveTakeUsd: number
  rewardsDistributedUsd: number
  swapFeesUsd: number
}

/** Daily-revenue → monthly rollup. Missing months are zero-filled (12 points). */
export function rollupMonthlyRevenue(
  rows: ReadonlyArray<RevenueDailyAmounts>,
  now = new Date(),
): MonthlyRevenueBucket[] {
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - (CASHFLOW_MONTHS - 1), 1))
  const startDay = start.toISOString().slice(0, 10)

  const buckets = new Map<string, MonthlyRevenueBucket>()
  for (let i = 0; i < CASHFLOW_MONTHS; i++) {
    const d = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + i, 1))
    const key = d.toISOString().slice(0, 7) + "-01"
    buckets.set(key, {
      month: key,
      interestFromBorrowersUsd: 0,
      interestToSuppliersUsd: 0,
      reserveTakeUsd: 0,
      rewardsDistributedUsd: 0,
      swapFeesUsd: 0,
    })
  }
  for (const row of rows) {
    if (row.day < startDay) continue
    const key = row.day.slice(0, 7) + "-01"
    const b = buckets.get(key)
    if (!b) continue
    b.interestFromBorrowersUsd += row.interestFromBorrowersUsd
    b.interestToSuppliersUsd += row.interestToSuppliersUsd
    b.reserveTakeUsd += row.reserveTakeUsd
    b.rewardsDistributedUsd += row.rewardsDistributedUsd
    b.swapFeesUsd += row.swapFeesUsd
  }
  return [...buckets.values()]
}

export function buildCashflowBreakdown(
  monthly: MonthlyRevenueBucket[],
  seriesIdPrefix: string,
  scope: "asset" | "pool" | "lend" | "multiply",
) {
  const ttm = monthly.reduce(
    (acc, m) => ({
      interestFromBorrowersUsd: acc.interestFromBorrowersUsd + m.interestFromBorrowersUsd,
      interestToSuppliersUsd: acc.interestToSuppliersUsd + m.interestToSuppliersUsd,
      reserveTakeUsd: acc.reserveTakeUsd + m.reserveTakeUsd,
      rewardsDistributedUsd: acc.rewardsDistributedUsd + m.rewardsDistributedUsd,
      swapFeesUsd: acc.swapFeesUsd + m.swapFeesUsd,
    }),
    {
      interestFromBorrowersUsd: 0,
      interestToSuppliersUsd: 0,
      reserveTakeUsd: 0,
      rewardsDistributedUsd: 0,
      swapFeesUsd: 0,
    },
  )

  const feesSeries = {
    id: `${seriesIdPrefix}:cf:fees`,
    label: scope === "pool" ? "Swap fees" : "Interest",
    points: monthly.map((m) => ({ t: m.month, v: scope === "pool" ? m.swapFeesUsd : m.interestFromBorrowersUsd })),
  }
  const rewardsSeries = {
    id: `${seriesIdPrefix}:cf:rewards`,
    label: "Rewards",
    points: monthly.map((m) => ({ t: m.month, v: m.rewardsDistributedUsd })),
  }

  const rows =
    scope === "pool"
      ? [
          { label: "Swap fees", reported: formatCompactUsdStatic(ttm.swapFeesUsd), highlighted: true },
          { label: "LP incentives", reported: formatCompactUsdStatic(ttm.rewardsDistributedUsd) },
          { label: "Protocol revenue", reported: formatCompactUsdStatic(ttm.reserveTakeUsd) },
          {
            label: "Net to suppliers",
            reported: formatCompactUsdStatic(ttm.interestToSuppliersUsd + ttm.swapFeesUsd * 0.9),
            highlighted: true,
          },
        ]
      : [
          {
            label: "Interest paid by borrowers",
            reported: formatCompactUsdStatic(ttm.interestFromBorrowersUsd),
            highlighted: true,
          },
          { label: "To suppliers", reported: formatCompactUsdStatic(ttm.interestToSuppliersUsd) },
          { label: "Reserve", reported: formatCompactUsdStatic(ttm.reserveTakeUsd) },
          { label: "Rewards distributed", reported: formatCompactUsdStatic(ttm.rewardsDistributedUsd) },
          {
            label: "Net to suppliers",
            reported: formatCompactUsdStatic(ttm.interestToSuppliersUsd + ttm.rewardsDistributedUsd),
            highlighted: true,
          },
        ]

  return {
    bars: [feesSeries, rewardsSeries],
    periodLabel: "Last 12 months",
    rows,
  }
}

export function buildRevenueTrend(monthly: MonthlyRevenueBucket[], seriesIdPrefix: string) {
  const points = monthly.map((m) => ({ t: m.month, v: m.interestFromBorrowersUsd }))
  const total = points.reduce((a, p) => a + p.v, 0)
  return {
    totalLabel: formatCompactUsdStatic(total),
    periodLabel: "Yearly",
    series: {
      id: `${seriesIdPrefix}:cf:revenue`,
      label: "Revenue",
      points,
      aggregate: total / Math.max(1, points.length),
    },
  }
}

/** Load siloed daily revenue rows for a slug from the last ~12 months window. */
export async function loadSiloedRevenueDaily(
  ctx: QueryCtx,
  table: "borrowRevenueDaily" | "lendRevenueDaily" | "multiplyRevenueDaily",
  slug: string,
  now = new Date(),
): Promise<RevenueDailyAmounts[]> {
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - (CASHFLOW_MONTHS - 1), 1))
  const startDay = start.toISOString().slice(0, 10)
  const rows = await ctx.db
    .query(table)
    .withIndex("by_slug_day", (q) => q.eq("slug", slug).gte("day", startDay))
    .collect()
  return rows.map((row) => ({
    day: row.day,
    interestFromBorrowersUsd: row.interestFromBorrowersUsd,
    interestToSuppliersUsd: row.interestToSuppliersUsd,
    reserveTakeUsd: row.reserveTakeUsd,
    rewardsDistributedUsd: row.rewardsDistributedUsd,
    swapFeesUsd: row.swapFeesUsd,
  }))
}
