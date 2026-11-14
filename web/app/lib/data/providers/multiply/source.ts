import {
  type DataSourceAdapter,
  type DataSourceRequestContext,
  type DataSourceResponse,
} from "@/app/lib/data/core/source-runtime"
import { createCatalogPageSources } from "@/app/lib/data/providers/catalog-page-source"
import { buildMultiplyPageData } from "@/app/lib/multiply-system/read-model"
import { buildMultiplyCatalogBaselineState } from "@/app/lib/multiply-system/mock"
import { mergeConvexMultiplySnapshots } from "@/app/lib/multiply-system/market-hydration"
import {
  fetchMultiplyMarketSnapshots,
  fetchMultiplyTokenParameters,
} from "@/app/lib/multiply-system/market-hydration-server"
import type { MultiplyPageData } from "./types"

export type MultiplyPageSource = {
  adapter: DataSourceAdapter
  getMultiplyPageData(context?: DataSourceRequestContext): Promise<DataSourceResponse<MultiplyPageData>>
}

const catalogSources = createCatalogPageSources({
  product: "multiply",
  buildBaselineState: buildMultiplyCatalogBaselineState,
  fetchSnapshots: fetchMultiplyMarketSnapshots,
  mergeSnapshots: mergeConvexMultiplySnapshots,
  // Fetch the live token parameters server-side too, so the SSR page carries real
  // APYs/logos — the client then renders them on first paint instead of the bundled
  // static constants (kills the mock-then-live swap). Degrades to undefined (→ static
  // fallback) only when Convex is unreachable.
  readPageData: async (state, walletId) => {
    const convexTokens = await fetchMultiplyTokenParameters()
    return buildMultiplyPageData(walletId, state, convexTokens.length > 0 ? convexTokens : undefined)
  },
  mockWalletId: "catalog",
})

const mockMultiplyPageAdapter = catalogSources.mockAdapter
const liveMultiplyPageAdapter = catalogSources.liveAdapter

export const mockMultiplyPageSource: MultiplyPageSource = {
  adapter: mockMultiplyPageAdapter,
  getMultiplyPageData: (context) => catalogSources.mockSource.getPageData(context),
}

export const liveMultiplyPageSource: MultiplyPageSource = {
  adapter: liveMultiplyPageAdapter,
  getMultiplyPageData: (context) => catalogSources.liveSource.getPageData(context),
}
