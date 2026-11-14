import { buildBorrowCatalogBaselineState } from "@/app/lib/borrow-system/mock"
import { mergeConvexMarketSnapshots } from "@/app/lib/borrow-system/market-hydration"
import { fetchConvexMarketSnapshots } from "@/app/lib/borrow-system/market-hydration-server"
import { SandboxBorrowReadAdapter } from "@/app/lib/borrow-system/sandbox-read-adapter"
import {
  type DataSourceAdapter,
  type DataSourceRequestContext,
  type DataSourceResponse,
} from "@/app/lib/data/core/source-runtime"
import { createCatalogPageSources } from "@/app/lib/data/providers/catalog-page-source"
import { getDefaultWalletProfileId } from "@/app/lib/data/wallet/profiles"
import type { BorrowPageData } from "./types"

export type BorrowPageSource = {
  adapter: DataSourceAdapter
  getBorrowPageData(context?: DataSourceRequestContext): Promise<DataSourceResponse<BorrowPageData>>
}

const catalogSources = createCatalogPageSources({
  product: "borrow",
  buildBaselineState: buildBorrowCatalogBaselineState,
  fetchSnapshots: fetchConvexMarketSnapshots,
  mergeSnapshots: mergeConvexMarketSnapshots,
  readPageData: async (state, walletId) => {
    const readAdapter = new SandboxBorrowReadAdapter({ state })
    return readAdapter.readBorrowPage(walletId)
  },
  mockWalletId: getDefaultWalletProfileId(),
})

const mockBorrowPageAdapter = catalogSources.mockAdapter
const liveBorrowPageAdapter = catalogSources.liveAdapter

export const mockBorrowPageSource: BorrowPageSource = {
  adapter: mockBorrowPageAdapter,
  getBorrowPageData: (context) => catalogSources.mockSource.getPageData(context),
}

export const liveBorrowPageSource: BorrowPageSource = {
  adapter: liveBorrowPageAdapter,
  getBorrowPageData: (context) => catalogSources.liveSource.getPageData(context),
}
