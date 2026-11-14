import type { HomeCollateralPool } from "@/app/lib/data/borrow-domain"

export type DebtRowContext = {
  id?: string
  pool: HomeCollateralPool
  /** Venue-scoped borrow asset id (e.g. `bal-stable:gho`) — links the row to its asset detail page. */
  debtAssetId?: string
  debtAssetSymbol: string
  borrowedUsd: number
  liquidationThresholdUsd: number
  healthFactor: number | null
  borrowApr: number
  accruedInterestUsd: number
  dailyInterestUsd: number
}

export type SupplyRowContext = {
  pool: HomeCollateralPool
  borrowedUsd: number
  remainingBorrowPowerUsd: number
  liquidationThresholdUsd: number
  healthFactor: number | null
  pairApr: number
  feesUsd: number
  feesLabel: string
}
