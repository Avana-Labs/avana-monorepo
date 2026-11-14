import {
  createDataSourceAdapter,
  DataSourceError,
  type DataSourceAdapter,
  type DataSourceRequestContext,
  type DataSourceResponse,
} from "@/app/lib/data/core/source-runtime"

type CatalogPageReader<State, PageData> = (state: State, walletId: string) => Promise<PageData> | PageData

type CatalogPageSource<PageData> = {
  adapter: DataSourceAdapter
  getPageData(context?: DataSourceRequestContext): Promise<DataSourceResponse<PageData>>
}

type CreateCatalogPageSourcesOptions<State, Snapshot, PageData> = {
  product: string
  buildBaselineState: (walletId: string) => State
  fetchSnapshots: () => Promise<ReadonlyArray<Snapshot>>
  mergeSnapshots: (state: State, snapshots: ReadonlyArray<Snapshot>) => State
  readPageData: CatalogPageReader<State, PageData>
  mockWalletId?: string
  liveWalletId?: string
}

export function createCatalogPageSources<State, Snapshot, PageData>({
  product,
  buildBaselineState,
  fetchSnapshots,
  mergeSnapshots,
  readPageData,
  mockWalletId = "demo-wallet",
  liveWalletId = "catalog",
}: CreateCatalogPageSourcesOptions<State, Snapshot, PageData>) {
  const productLabel = product[0].toUpperCase() + product.slice(1)

  const mockAdapter = createDataSourceAdapter({
    id: `${product}-mock`,
    label: `${productLabel} page mock source`,
    mode: "mock",
  })

  const liveAdapter = createDataSourceAdapter({
    id: `${product}-live`,
    label: `${productLabel} page live source`,
    mode: "live",
  })

  async function buildPageData(walletId: string, requireSnapshots: boolean): Promise<DataSourceResponse<PageData>> {
    const snapshots = requireSnapshots ? await fetchSnapshots() : []
    if (requireSnapshots && snapshots.length === 0) {
      throw new DataSourceError({
        code: "unavailable",
        sourceId: liveAdapter.id,
        operation: "getPageData",
        message: `Convex returned no ${productLabel} market snapshots. Seed the market catalog before enabling live mode.`,
        retryable: true,
      })
    }

    const baseline = buildBaselineState(walletId)
    const state = snapshots.length > 0 ? mergeSnapshots(baseline, snapshots) : baseline

    return {
      fetchedAt: new Date().toISOString(),
      data: await readPageData(state, walletId),
    }
  }

  const mockSource: CatalogPageSource<PageData> = {
    adapter: mockAdapter,
    async getPageData() {
      return buildPageData(mockWalletId, false)
    },
  }

  const liveSource: CatalogPageSource<PageData> = {
    adapter: liveAdapter,
    async getPageData() {
      return buildPageData(liveWalletId, true)
    },
  }

  return { mockAdapter, liveAdapter, mockSource, liveSource }
}
