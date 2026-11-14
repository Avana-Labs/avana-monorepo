import type { BorrowableAsset } from "@/app/lib/borrow-sim"
import {
  BORROW_DEXES,
  BORROW_PENDING_ROWS,
  BORROW_POOL_CATALOG,
  HOME_COLLATERAL_POOLS,
} from "@/app/lib/data/catalog/borrow"

export type BorrowPageData = {
  walletId: string
  borrowSessionSeed: string
  poolCatalog: ReadonlyArray<(typeof BORROW_POOL_CATALOG)[number]>
  heroMetrics: {
    totalTvlUsd: number
    totalCollateralUsd: number
    availableCreditUsd: number
    outstandingLoansUsd: number
    totalTvlChangePct: number
  }
  borrowableAssets: ReadonlyArray<BorrowableAsset>
  pendingRows: ReadonlyArray<(typeof BORROW_PENDING_ROWS)[number]>
  dexes: ReadonlyArray<(typeof BORROW_DEXES)[number]>
  collateralPools: ReadonlyArray<(typeof HOME_COLLATERAL_POOLS)[number]>
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
  | "borrowSessionSeed"
  | "poolCatalog"
  | "borrowableAssets"
  | "pendingRows"
  | "dexes"
  | "collateralPools"
  | "initialDebts"
  | "borrowSnapshot"
>
