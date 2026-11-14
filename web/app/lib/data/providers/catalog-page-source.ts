import {
  createDataSourceAdapter,
  type DataSourceAdapter,
  type DataSourceRequestContext,
  type DataSourceResponse,
} from "@/app/lib/data/core/source-runtime"

type MarketPageReader<State, PageData> = (state: State, walletId: string) => Promise<PageData> | PageData

type MarketPageSource<PageData> = {
  adapter: DataSourceAdapter
  getPageData(context?: DataSourceRequestContext): Promise<DataSourceResponse<PageData>>
}

type CreateMarketPageSourceOptions<State, Snapshot, PageData> = {
  product: string
  buildEmptyState: (walletId: string) => State
  fetchSnapshots: () => Promise<ReadonlyArray<Snapshot>>
  mergeSnapshots: (state: State, snapshots: ReadonlyArray<Snapshot>) => State
  readPageData: MarketPageReader<State, PageData>
  walletId?: string
}

/**
 * A list page's server source: the markets services/convex reports, read into the page shape.
 * With no rows (no deployment configured, or nothing listed yet) the page renders its empty state.
 */
export function createMarketPageSource<State, Snapshot, PageData>({
  product,
  buildEmptyState,
  fetchSnapshots,
  mergeSnapshots,
  readPageData,
  walletId = "guest-wallet",
}: CreateMarketPageSourceOptions<State, Snapshot, PageData>): MarketPageSource<PageData> {
  const productLabel = product[0].toUpperCase() + product.slice(1)
  const adapter = createDataSourceAdapter({
    id: `${product}-live`,
    label: `${productLabel} page source`,
    mode: "live",
  })

  return {
    adapter,
    async getPageData() {
      const snapshots = await fetchSnapshots()
      const state = mergeSnapshots(buildEmptyState(walletId), snapshots)
      return { fetchedAt: new Date().toISOString(), data: await readPageData(state, walletId) }
    },
  }
}
