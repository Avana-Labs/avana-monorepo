import { emptyBorrowSystemState, mergeConvexMarketSnapshots } from "@/app/lib/borrow-system/market-hydration"
import { fetchConvexMarketSnapshots } from "@/app/lib/borrow-system/market-hydration-server"
import { buildBorrowPageData } from "@/app/lib/borrow-system/read-model"
import type {
  DataSourceAdapter,
  DataSourceRequestContext,
  DataSourceResponse,
} from "@/app/lib/data/core/source-runtime"
import { createMarketPageSource } from "@/app/lib/data/providers/catalog-page-source"
import type { BorrowPageData } from "./types"

export type BorrowPageSource = {
  adapter: DataSourceAdapter
  getBorrowPageData(context?: DataSourceRequestContext): Promise<DataSourceResponse<BorrowPageData>>
}

const source = createMarketPageSource({
  product: "borrow",
  buildEmptyState: (walletId) => emptyBorrowSystemState(walletId),
  fetchSnapshots: fetchConvexMarketSnapshots,
  mergeSnapshots: mergeConvexMarketSnapshots,
  readPageData: (state, walletId) => buildBorrowPageData(state, walletId),
})

export const liveBorrowPageSource: BorrowPageSource = {
  adapter: source.adapter,
  getBorrowPageData: (context) => source.getPageData(context),
}
