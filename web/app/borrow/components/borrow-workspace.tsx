"use client"

import { useCallback, useEffect, useMemo, useState } from "react"
import { useRouter, useSearchParams } from "next/navigation"
import {
  filterPools,
  groupByDex,
  orderPoolsForDexGroups,
  type BorrowPoolRow,
  type BorrowableAsset,
} from "@/app/lib/data/borrow-domain"
import type { BorrowWorkspaceData } from "@/app/lib/data/providers/borrow"
import type { SupplyRowContext } from "@/app/lib/data/borrow-position-types"
import { selectPortfolioSupplyRows } from "@/app/lib/borrow-system/dashboard-selectors"
import { actionPagePath } from "@/app/lib/action-system/contracts"
import { borrowAssetDetailPath, borrowMarketDetailPath } from "@/app/lib/borrow-routes"
import { triggerPageLoading } from "@/app/lib/page-loading"
import { useBorrowSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { useMarketLiquidity } from "@/app/lib/convex/market-liquidity-provider"
import { applyBorrowableAssetDelta } from "@/app/lib/market-liquidity/apply"
import { TabsBar } from "./tabs-bar"
import { CollateralPoolsTable } from "./collateral-pools-table"
import { useMediaQuery } from "@/app/lib/use-media-query"
import {
  EMPTY_MARKET_FILTERS,
  activeFilterCount,
  borrowPoolFilterItem,
  borrowPoolSymbols,
  buildAssetOptions,
  matchesMarketFilters,
  type MarketFilterState,
} from "@/app/lib/markets/filters"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { RevealSentinel, useProgressiveReveal } from "@/app/lib/ui/use-progressive-reveal"

// Curated (protocol-strategy) spokes that belong in "smart" regardless of their tokens.
export const SMART_SPOKES = new Set<string>([
  "uni-v2",
  "uni-v3-stable",
  "uni-v3-bluechip",
  "curve-crypto",
  "bal-weighted",
  "bal-boosted",
  "bal-reclamm",
  "aero-slipstream-bluechip",
])

const BORROW_MARKETS_PAGE_SIZE = 12

type BorrowWorkspaceProps = {
  pageData: BorrowWorkspaceData
  initialIsDesktop?: boolean
}

export function BorrowWorkspace({ pageData, initialIsDesktop = true }: BorrowWorkspaceProps) {
  const router = useRouter()
  const isDesktop = useMediaQuery("(min-width: 768px)", initialIsDesktop, true)
  const { pendingRows } = pageData
  const session = useBorrowSessionContext()
  const { deltas: liquidityDeltas } = useMarketLiquidity()
  const searchParams = useSearchParams()
  const [filters, setFilters] = useState<MarketFilterState>(EMPTY_MARKET_FILTERS)
  const [search, setSearch] = useState(() => searchParams?.get("q") ?? "")

  // Keep the search in sync with the URL when a header mega-menu "View all" changes the query on
  // this same page; the #markets hash on the link handles scrolling to this list.
  const queryParam = searchParams?.get("q")
  useEffect(() => {
    if (queryParam) setSearch(queryParam)
  }, [queryParam])

  const marketSpokeById = useMemo(
    () => new Map(pageData.poolCatalog.map((market) => [market.id, market.spoke])),
    [pageData.poolCatalog],
  )

  // Data for each tab
  const supplies = useMemo<SupplyRowContext[]>(() => {
    return selectPortfolioSupplyRows(session.state, pageData.walletId)
  }, [pageData.walletId, session.state])

  const filteredPools = useMemo(() => {
    return filterPools([...pageData.poolCatalog], { text: search })
  }, [pageData.poolCatalog, search])

  const filterItemById = useMemo(
    () => new Map(pageData.poolCatalog.map((pool) => [pool.id, borrowPoolFilterItem(pool)])),
    [pageData.poolCatalog],
  )
  const filterItems = useMemo(() => [...filterItemById.values()], [filterItemById])
  const assetOptions = useMemo(
    () =>
      buildAssetOptions(pageData.poolCatalog.flatMap((pool) => borrowPoolSymbols(pool).map((symbol) => ({ symbol })))),
    [pageData.poolCatalog],
  )

  const visiblePools = useMemo(() => {
    const matching = filteredPools.filter((pool) => {
      const item = filterItemById.get(pool.id)
      return item ? matchesMarketFilters(item, filters) : false
    })
    // Group order up front, so revealing the next chunk only appends below (see orderPoolsForDexGroups).
    return orderPoolsForDexGroups(matching)
  }, [filterItemById, filteredPools, filters])

  // Reveal markets on scroll instead of paginating: the first chunk renders up
  // front, then the sentinel eases in the rest as the user scrolls down.
  const { visibleCount, hasMore, isRevealing, sentinelRef } = useProgressiveReveal({
    total: visiblePools.length,
    chunkSize: BORROW_MARKETS_PAGE_SIZE,
    resetKey: `${JSON.stringify(filters)}|${search.trim().toLowerCase()}`,
  })
  const revealedPools = useMemo(() => visiblePools.slice(0, visibleCount), [visiblePools, visibleCount])
  const poolGroups = useMemo(() => groupByDex(revealedPools), [revealedPools])
  // The "Borrowable" tab in the UI (labelled "Assets"→"Borrowable") is fed from here:
  // Keep the server-loaded public market snapshot through hydration. Session data
  // is wallet-specific and can hydrate later with a different mock snapshot; using
  // it here makes every public market number visibly swap after first paint.
  const borrowAssetsBySpoke = useMemo(() => {
    const assetsBySpoke = new Map<string, BorrowableAsset[]>()
    for (const asset of pageData.borrowableAssets) {
      const spokeId = asset.id.includes(":") ? asset.id.split(":")[0] : ""
      if (!spokeId) continue
      const assets = assetsBySpoke.get(spokeId) ?? []
      assets.push(applyBorrowableAssetDelta(asset, liquidityDeltas))
      assetsBySpoke.set(spokeId, assets)
    }

    const next: Record<string, BorrowableAsset[]> = {}
    for (const group of poolGroups) {
      for (const entry of group.spokes) {
        next[entry.spoke.id] = assetsBySpoke.get(entry.spoke.id) ?? []
      }
    }
    return next
  }, [liquidityDeltas, pageData.borrowableAssets, poolGroups])

  const hasActiveFilters = search.trim().length > 0 || activeFilterCount(filters) > 0
  const clearFilters = useCallback(() => {
    setSearch("")
    setFilters(EMPTY_MARKET_FILTERS)
  }, [])

  const handlePoolsSupply = useCallback(
    (pool: BorrowPoolRow) => {
      triggerPageLoading()
      router.push(actionPagePath("borrow", "supply", { market: pool.id }))
    },
    [router],
  )

  const handleMarketDetail = useCallback(
    (pool: BorrowPoolRow) => {
      triggerPageLoading()
      router.push(borrowMarketDetailPath(pool.id))
    },
    [router],
  )

  const handleAssetBorrowDesktop = useCallback(
    (asset: BorrowableAsset) => {
      triggerPageLoading()
      router.push(borrowAssetDetailPath(asset.id))
    },
    [router],
  )

  const handleAssetBorrowMobile = useCallback(
    (asset: BorrowableAsset) => {
      const assetSpokeId = asset.id.includes(":") ? asset.id.split(":")[0] : null
      const sameSpokeSupplies = supplies.filter((row) => {
        if (!assetSpokeId) return false
        if (marketSpokeById.get(row.pool.id) !== assetSpokeId) return false
        return Number.isFinite(row.healthFactor ?? NaN) || row.borrowedUsd === 0
      })
      const best = sameSpokeSupplies.reduce<SupplyRowContext | null>((acc, row) => {
        if (!acc) return row
        const rowScore = Number.isFinite(row.healthFactor ?? NaN) ? (row.healthFactor as number) : 99
        const accScore = Number.isFinite(acc.healthFactor ?? NaN) ? (acc.healthFactor as number) : 99
        return rowScore >= accScore ? row : acc
      }, null)
      if (!best) {
        triggerPageLoading()
        router.push(borrowAssetDetailPath(asset.id))
        return
      }
      triggerPageLoading()
      router.push(
        actionPagePath("borrow", "borrow", {
          market: best.pool.id,
          asset: asset.id,
        }),
      )
    },
    [marketSpokeById, router, supplies],
  )

  return (
    <section id="markets" className="scroll-mt-24 pb-16">
      <TabsBar
        items={filterItems}
        filters={filters}
        onFiltersChange={setFilters}
        assetOptions={assetOptions}
        search={search}
        onSearchChange={setSearch}
      />

      {/* At least one screen tall, so narrowing the filters never shortens the page enough to
          force the browser to pull the scroll position back. */}
      <div className="min-h-[100svh] pt-3 pb-6">
        {/* Prices come from the global seeded TokenPricesProvider (ProductRuntimeProviders); a
            local provider here would shadow that seed with an empty context → fixture prices. */}
        {visiblePools.length === 0 ? (
          <NoMarketsState query={search.trim()} hasFilters={hasActiveFilters} onClear={clearFilters} />
        ) : (
          <CollateralPoolsTable
            groups={poolGroups}
            borrowAssetsBySpoke={borrowAssetsBySpoke}
            pending={pendingRows}
            onViewMarket={handleMarketDetail}
            onUseAsCollateral={handlePoolsSupply}
            // Desktop Borrow opens the asset page; on phones it jumps straight into the
            // borrow flow against the healthiest same-spoke collateral.
            onBorrowAsset={isDesktop ? handleAssetBorrowDesktop : handleAssetBorrowMobile}
          />
        )}
      </div>

      {hasMore ? <RevealSentinel sentinelRef={sentinelRef} active={isRevealing} /> : null}
    </section>
  )
}

function NoMarketsState({ query, hasFilters, onClear }: { query: string; hasFilters: boolean; onClear: () => void }) {
  const { t } = useTranslation()
  return (
    <div
      role="status"
      className="flex flex-col items-center justify-center gap-3 rounded-radius-md border border-dashed border-border px-6 py-16 text-center"
    >
      <p className="text-[15px] font-medium text-foreground">
        {query ? t("No markets match “{query}”").replace("{query}", query) : t("No markets match your filters")}
      </p>
      <p className="max-w-sm text-[13px] leading-6 text-muted-foreground">
        {t("Try a different token, venue, or clear the search to see every market.")}
      </p>
      {hasFilters ? (
        <button
          type="button"
          onClick={onClear}
          className="mt-1 rounded-full border border-border px-4 py-1.5 text-[13px] font-medium text-foreground transition-colors hover:bg-hover"
        >
          {t("Clear filters")}
        </button>
      ) : null}
    </div>
  )
}
