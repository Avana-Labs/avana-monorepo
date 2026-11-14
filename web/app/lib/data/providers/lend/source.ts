import {
  type DataSourceAdapter,
  type DataSourceRequestContext,
  type DataSourceResponse,
} from "@/app/lib/data/core/source-runtime"
import { createCatalogPageSources } from "@/app/lib/data/providers/catalog-page-source"
import { buildLendCatalogBaselineState } from "@/app/lib/lend-system/mock"
import { SandboxLendReadAdapter } from "@/app/lib/lend-system/sandbox-read-adapter"
import { mergeConvexLendSnapshots } from "@/app/lib/lend-system/market-hydration"
import { fetchLendMarketSnapshots } from "@/app/lib/lend-system/market-hydration-server"
import type { LendPageData } from "./types"

export type LendPageSource = {
  adapter: DataSourceAdapter
  getLendPageData(context?: DataSourceRequestContext): Promise<DataSourceResponse<LendPageData>>
}

const catalogSources = createCatalogPageSources({
  product: "lend",
  buildBaselineState: buildLendCatalogBaselineState,
  fetchSnapshots: fetchLendMarketSnapshots,
  mergeSnapshots: mergeConvexLendSnapshots,
  readPageData: async (state, walletId) => {
    const readAdapter = new SandboxLendReadAdapter({ state })
    return readAdapter.readLendPage(walletId)
  },
})

const mockLendPageAdapter = catalogSources.mockAdapter
const liveLendPageAdapter = catalogSources.liveAdapter

export const mockLendPageSource: LendPageSource = {
  adapter: mockLendPageAdapter,
  getLendPageData: (context) => catalogSources.mockSource.getPageData(context),
}

export const liveLendPageSource: LendPageSource = {
  adapter: liveLendPageAdapter,
  getLendPageData: (context) => catalogSources.liveSource.getPageData(context),
}
