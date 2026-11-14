import type {
  DataSourceAdapter,
  DataSourceRequestContext,
  DataSourceResponse,
} from "@/app/lib/data/core/source-runtime"
import { createMarketPageSource } from "@/app/lib/data/providers/catalog-page-source"
import { buildLendPageData } from "@/app/lib/lend-system/read-model"
import { mergeConvexLendSnapshots } from "@/app/lib/lend-system/market-hydration"
import { fetchLendMarketSnapshots } from "@/app/lib/lend-system/market-hydration-server"
import { emptyLendSystemState } from "@/app/lib/lend-system/market-hydration"
import type { LendPageData } from "./types"

export type LendPageSource = {
  adapter: DataSourceAdapter
  getLendPageData(context?: DataSourceRequestContext): Promise<DataSourceResponse<LendPageData>>
}

const source = createMarketPageSource({
  product: "lend",
  buildEmptyState: (walletId) => emptyLendSystemState(walletId),
  fetchSnapshots: fetchLendMarketSnapshots,
  mergeSnapshots: mergeConvexLendSnapshots,
  readPageData: (state, walletId) => buildLendPageData(walletId, state),
})

export const liveLendPageSource: LendPageSource = {
  adapter: source.adapter,
  getLendPageData: (context) => source.getPageData(context),
}
