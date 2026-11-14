import type { BorrowDex, BorrowPoolRow, BorrowableAsset, PendingMarketRow } from "@/app/lib/borrow-market-rows"
import type { HomeCollateralPool } from "@/app/lib/home-view-model"

export type BorrowPageData = {
  walletId: string
  poolCatalog: ReadonlyArray<BorrowPoolRow>
  heroMetrics: {
    totalTvlUsd: number
    totalCollateralUsd: number
    availableCreditUsd: number
    outstandingLoansUsd: number
    totalTvlChangePct: number
  }
  borrowableAssets: ReadonlyArray<BorrowableAsset>
  pendingRows: ReadonlyArray<PendingMarketRow>
  dexes: ReadonlyArray<BorrowDex>
  collateralPools: ReadonlyArray<HomeCollateralPool>
  initialDebts: Record<string, number>
  borrowSnapshot: {
    totalBorrowedUsd: number
    availableCreditUsd: number
    totalCollateralUsd: number
    liquidationValueUsd: number
    healthFactor: number | null
  }
}

export type BorrowWorkspaceData = Pick<
  BorrowPageData,
  | "walletId"
  | "poolCatalog"
  | "borrowableAssets"
  | "pendingRows"
  | "dexes"
  | "collateralPools"
  | "initialDebts"
  | "borrowSnapshot"
>
