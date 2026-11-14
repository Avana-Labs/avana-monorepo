/**
 * Single contract for Borrow landing hero aggregates.
 * Same field math whether computed from listMarketSnapshots rows or daily tips:
 *   - totalCollateralUsd  = Σ pool tvlUsd (fallback suppliedUsd)
 *   - outstandingLoansUsd = Σ asset borrowedUsd  (never asset suppliedUsd)
 *   - availableCreditUsd  = Σ pool availableUsd
 */

export type BorrowEconomySnapshotRow = {
  slug: string
  scope: string
  tvlUsd?: number
  suppliedUsd: number
  borrowedUsd: number
  availableUsd: number
}

export type BorrowEconomyAggregates = {
  totalCollateralUsd: number
  outstandingLoansUsd: number
  availableCreditUsd: number
  poolMarkets: number
  assetMarkets: number
}

function poolCollateralUsd(row: BorrowEconomySnapshotRow) {
  if (row.tvlUsd !== undefined && Number.isFinite(row.tvlUsd)) return Math.max(0, row.tvlUsd)
  return Math.max(0, row.suppliedUsd)
}

export function aggregateBorrowEconomyFromSnapshots(
  rows: readonly BorrowEconomySnapshotRow[],
): BorrowEconomyAggregates {
  let totalCollateralUsd = 0
  let outstandingLoansUsd = 0
  let availableCreditUsd = 0
  let poolMarkets = 0
  let assetMarkets = 0

  for (const row of rows) {
    if (row.scope === "pool") {
      poolMarkets += 1
      totalCollateralUsd += poolCollateralUsd(row)
      availableCreditUsd += Math.max(0, row.availableUsd)
    } else if (row.scope === "asset") {
      assetMarkets += 1
      outstandingLoansUsd += Math.max(0, row.borrowedUsd)
    }
  }

  return {
    totalCollateralUsd,
    outstandingLoansUsd,
    availableCreditUsd,
    poolMarkets,
    assetMarkets,
  }
}
