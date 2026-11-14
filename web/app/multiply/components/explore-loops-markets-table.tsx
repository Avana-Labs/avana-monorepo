"use client"

import * as React from "react"
import { ActionIcon } from "@/app/components/action-icon"
import { CapacityFilled } from "@/app/components/capacity-filled"
import Link from "next/link"
import { useRouter, useSearchParams } from "next/navigation"
import {
  DesktopTableSurface,
  HoverActionGroup,
  ScrollableTable,
  SortHeaderButton,
} from "@/app/components/market-table-primitives"
import { TokenIcon } from "@/app/components/token-icon"
import {
  TOKEN_ICON_TABLE_PAIR_WIDTH_PX,
  TOKEN_ICON_TABLE_PX,
  TOKEN_ICON_TRENDING_PX,
  pairedLoopBorrowPx,
  pairedLoopContainerWidthPx,
} from "@/app/lib/token-icon-sizes"
import { actionPagePath } from "@/app/lib/action-system/contracts"
import type { MultiplyPageData } from "@/app/lib/data/providers/multiply"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"
import { CarouselArrowButtons } from "@/app/components/carousel-arrow-buttons"
import { HowItWorks } from "@/app/components/how-it-works"
import {
  HIGHLIGHT_CARD_CLASS,
  HighlightCarousel,
  type HighlightCarouselHandle,
} from "@/app/components/highlight-carousel"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { MarketFiltersBar, MarketFiltersEmptyState } from "@/app/lib/ui/market-filters"
import { categorizeMarket } from "@/app/lib/markets/category"
import {
  EMPTY_MARKET_FILTERS,
  MULTIPLY_MARKET_OPTIONS,
  activeFilterCount,
  buildAssetOptions,
  matchesMarketFilters,
  multiplyFilterItem,
  type FilterableItem,
  type MarketFilterState,
} from "@/app/lib/markets/filters"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import {
  translateMultiplyLoopBorrowLabel,
  translateMultiplyLoopSupplyLabel,
} from "@/app/lib/multiply-system/market-labels"
import { RevealSentinel, useProgressiveReveal } from "@/app/lib/ui/use-progressive-reveal"

const isMultiplyCategory = (value: string) => MULTIPLY_MARKET_OPTIONS.some((option) => option.id === value)

// Loop markets are grouped by their collateral asset's family, mirroring the Lend
// page's grouped asset tables (Stablecoins → Ethereum → Bitcoin → Other). Utility
// and Smart collateral both fall into "Other Assets".
type LoopGroupKey = "forex" | "eth" | "btc" | "other"

const LOOP_GROUP_ORDER: Array<{ key: LoopGroupKey; title: string }> = [
  { key: "forex", title: "Stablecoins" },
  { key: "eth", title: "Ethereum-Based" },
  { key: "btc", title: "Bitcoin Based" },
  { key: "other", title: "Other Assets" },
]

function loopGroupKey(collateralSymbol: string): LoopGroupKey {
  const category = categorizeMarket(collateralSymbol)
  return category === "forex" || category === "eth" || category === "btc" ? category : "other"
}

/**
 * Sort rows into the collateral-family order the table groups them by (stable within a family).
 * Progressive reveal slices BEFORE grouping; an unordered slice would add newly revealed rows to
 * groups above the viewport and push what the reader is looking at down the page.
 */
export function orderLoopRowsByGroup<Row extends { protocol: string }>(rows: readonly Row[]): Row[] {
  const rank = new Map(LOOP_GROUP_ORDER.map((group, index) => [group.key, index]))
  return rows
    .map((row, index) => ({ row, index, rank: rank.get(loopGroupKey(row.protocol)) ?? LOOP_GROUP_ORDER.length }))
    .sort((a, b) => a.rank - b.rank || a.index - b.index)
    .map((entry) => entry.row)
}

// Pure, row-only — hoisted out of the component so it isn't reallocated every render and
// can be memoised per `rows` instead of recomputed for every row on every keystroke.
function buildLoopSearchText(row: MultiplyPageData["lendRows"][number]): string {
  return [
    row.protocol,
    row.asset,
    row.kind,
    row.apy,
    row.apyLabel,
    row.partnerRewards ?? "",
    row.points ?? "",
    ...(row.rewardRows?.flatMap((reward) => [reward.label, reward.value]) ?? []),
  ]
    .join(" ")
    .toLowerCase()
}

import {
  TABLE_ACTION_BUTTON,
  TABLE_BODY_ROW,
  TABLE_CELL_CAPTION,
  TABLE_CELL_INDEX,
  TABLE_CELL_NUMERIC,
  TABLE_CELL_PADDING,
  TABLE_CELL_PADDING_LEADING,
  TABLE_CELL_PADDING_TRAILING,
  TABLE_CELL_PRIMARY,
  TABLE_CELL_SECONDARY,
  TABLE_HEADER_CELL,
  TABLE_HEADER_ROW,
  TABLE_INDEX_PHONE_HIDDEN,
  TABLE_ROW_HOVER_BG,
  TABLE_ROW_HOVER_RIGHT,
  tableColumnLayout,
  tableStickyCell,
} from "@/app/lib/ui/table-row-hover"

type LoopSortKey = "protocol" | "asset" | "apy" | "rewards" | "cf" | "capacityFilled" | "points"

function formatTrendingLeverageLabel(maxLeverageLabel: string) {
  const match = maxLeverageLabel.trim().match(/^([\d.]+)x$/i)
  if (!match) return maxLeverageLabel.toUpperCase()
  const value = Number.parseFloat(match[1] ?? "")
  if (!Number.isFinite(value)) return maxLeverageLabel.toUpperCase()
  const compact = Number.isInteger(value) ? String(value) : value.toFixed(1).replace(/\.0$/, "")
  return `${compact}X`
}

function parseCompactUsdLabel(value?: string) {
  if (!value) return null
  const match = value.trim().match(/^\$?([\d,.]+)([KMB])?$/i)
  if (!match) return null
  const amount = Number.parseFloat(match[1].replace(/,/g, ""))
  if (!Number.isFinite(amount)) return null
  const suffix = match[2]?.toUpperCase()
  return amount * (suffix === "B" ? 1e9 : suffix === "M" ? 1e6 : suffix === "K" ? 1e3 : 1)
}

function resolveMarketIdFromHref(href: string) {
  return href.split("/").pop() ?? ""
}

type ExploreLoopsMarketsTableProps = {
  rows: MultiplyPageData["lendRows"]
  trendingSnapshots: MultiplyPageData["trendingSnapshots"]
  pageSize: MultiplyPageData["pageSize"]
  tokenLogos: MultiplyPageData["tokenLogos"]
  onOpenMultiply?: (href: string) => void
}

export function isNegativeMultiplyApy(apy?: string) {
  if (!apy) return false
  const value = Number.parseFloat(apy.replace(/[^0-9.-]/g, ""))
  return Number.isFinite(value) && value < 0
}

export function ExploreLoopsMarketsTable({
  pageSize,
  rows,
  trendingSnapshots,
  tokenLogos: _tokenLogos,
}: ExploreLoopsMarketsTableProps) {
  const { t } = useTranslation()
  const searchParams = useSearchParams()
  // Deep links (e.g. the header mega-menu's "View all") can preselect a category via ?category=.
  const [filters, setFilters] = React.useState<MarketFilterState>(() => {
    const param = searchParams?.get("category")
    return { ...EMPTY_MARKET_FILTERS, markets: param && isMultiplyCategory(param) ? [param] : [] }
  })
  const [search, setSearch] = React.useState("")
  const searchQuery = search.trim().toLowerCase()

  // Keep the Markets filter in sync with the URL when a header mega-menu "View all" changes the
  // category on this same page; the #markets hash on the link handles scrolling to this table.
  const categoryParam = searchParams?.get("category")
  React.useEffect(() => {
    if (categoryParam && isMultiplyCategory(categoryParam)) {
      setFilters((current) => ({ ...current, markets: [categoryParam] }))
    }
  }, [categoryParam])

  const filterItemByRow = React.useMemo(() => {
    const map = new Map<(typeof rows)[number], FilterableItem>()
    for (const row of rows) map.set(row, multiplyFilterItem(row.protocol, row.asset))
    return map
  }, [rows])
  const filterItems = React.useMemo(() => [...filterItemByRow.values()], [filterItemByRow])
  const assetOptions = React.useMemo(
    () =>
      buildAssetOptions(
        rows.flatMap((row) => [
          { symbol: row.protocol, name: row.protocolName },
          { symbol: row.asset, name: row.assetName },
        ]),
      ),
    [rows],
  )

  // Compute each row's searchable text ONCE per `rows` change (keyed by row identity),
  // instead of rebuilding it for every row on every keystroke.
  const searchTextByRow = React.useMemo(() => {
    const map = new Map<(typeof rows)[number], string>()
    for (const row of rows) map.set(row, buildLoopSearchText(row))
    return map
  }, [rows])

  // Facet filter — recomputes only when the filters (or rows) change, so typing in search
  // doesn't re-run it. No active facet short-circuits to the full list.
  const categoryFilteredRows = React.useMemo(() => {
    if (activeFilterCount(filters) === 0) return rows
    return rows.filter((row) => {
      const item = filterItemByRow.get(row)
      return item ? matchesMarketFilters(item, filters) : false
    })
  }, [filters, filterItemByRow, rows])

  // Search filter runs over the already-category-filtered set using the precomputed text —
  // the only work a keystroke triggers now.
  const filteredRows = React.useMemo(() => {
    if (searchQuery.length === 0) return categoryFilteredRows
    return categoryFilteredRows.filter((row) => (searchTextByRow.get(row) ?? "").includes(searchQuery))
  }, [categoryFilteredRows, searchQuery, searchTextByRow])

  const effectivePageSize = Math.max(1, pageSize || 12)

  // Reveal rows on scroll instead of paginating: only the first chunk renders up
  // front, then the sentinel eases in the rest as the user scrolls down.
  const { visibleCount, hasMore, isRevealing, sentinelRef } = useProgressiveReveal({
    total: filteredRows.length,
    chunkSize: effectivePageSize,
    resetKey: `${JSON.stringify(filters)}|${searchQuery}`,
  })
  const orderedRows = React.useMemo(() => orderLoopRowsByGroup(filteredRows), [filteredRows])
  const revealedRows = React.useMemo(() => orderedRows.slice(0, visibleCount), [orderedRows, visibleCount])

  // Bucket the revealed rows into the ordered collateral-family groups, dropping
  // any empty group — the same grouped-table treatment the Lend page uses.
  const groupedSections = React.useMemo(() => {
    const buckets: Record<LoopGroupKey, Array<MultiplyPageData["lendRows"][number]>> = {
      forex: [],
      eth: [],
      btc: [],
      other: [],
    }
    for (const row of revealedRows) buckets[loopGroupKey(row.protocol)].push(row)
    return LOOP_GROUP_ORDER.map((group) => ({ title: group.title, rows: buckets[group.key] })).filter(
      (group) => group.rows.length > 0,
    )
  }, [revealedRows])

  const carouselRef = React.useRef<HighlightCarouselHandle>(null)

  return (
    <section id="markets" className="mt-7 scroll-mt-24">
      <div className="flex items-center justify-between gap-3">
        <h2 className="mt-1 text-[22px] font-normal tracking-[-0.01em] text-foreground md:text-[24px]">
          {t("Trending")}
        </h2>
        <div className="flex items-center gap-2.5">
          <HowItWorks topic="multiply" className="hidden md:inline-flex" />
          <CarouselArrowButtons
            canPrev
            canNext
            onPrev={() => carouselRef.current?.step(-1)}
            onNext={() => carouselRef.current?.step(1)}
            prevLabel="Previous trending"
            nextLabel="Next trending"
          />
        </div>
      </div>

      <HighlightCarousel
        ref={carouselRef}
        className="mt-5 h-[104px]"
        syncKey="multiply-trending"
        renderSequence={(interactive) =>
          trendingSnapshots.map((snapshot, index) => (
            <TrendingLoopCard
              key={`${interactive ? "a" : "b"}-${snapshot.marketId}-${index}`}
              snapshot={snapshot}
              interactive={interactive}
            />
          ))
        }
      />

      <MarketFiltersBar
        className="mt-11"
        items={filterItems}
        value={filters}
        onChange={setFilters}
        marketOptions={MULTIPLY_MARKET_OPTIONS}
        assetOptions={assetOptions}
        search={search}
        onSearchChange={setSearch}
        searchPlaceholder={t("Search loops")}
      />

      {/* At least one screen tall, so narrowing the filters never shortens the page enough to
          force the browser to pull the scroll position back. */}
      <div className="mt-[68px] min-h-[100svh] space-y-14">
        {groupedSections.length > 0 ? (
          groupedSections.map((group) => (
            <div key={group.title} className="space-y-8">
              <LoopMarketsSection title={group.title} rows={group.rows} />
              {group.title === "Ethereum-Based" ? (
                <div className="flex justify-center">
                  <div className="h-px w-full max-w-[980px] bg-gradient-to-r from-transparent via-border/80 to-transparent dark:via-white/10" />
                </div>
              ) : null}
            </div>
          ))
        ) : (
          <MarketFiltersEmptyState
            message={t("No loops match these filters.")}
            onClear={() => {
              setFilters(EMPTY_MARKET_FILTERS)
              setSearch("")
            }}
          />
        )}
      </div>

      {hasMore ? (
        <RevealSentinel
          sentinelRef={sentinelRef}
          active={isRevealing}
          className="mt-10 flex items-center justify-center py-8"
        />
      ) : null}
    </section>
  )
}

const LOOP_TABLE_LAYOUT = tableColumnLayout([
  "index",
  "identity",
  "compact", // APY
  "compact", // Leverage
  "compact", // CF
  "gauge", // Capacity filled
  "metric", // Available
  "action",
])

function LoopMarketsSection({ title, rows }: { title: string; rows: MultiplyPageData["lendRows"] }) {
  const { t } = useTranslation()
  const [sortKey, setSortKey] = React.useState<LoopSortKey>("protocol")
  const [sortDirection, setSortDirection] = React.useState<"asc" | "desc">("asc")

  const toggleSort = (nextKey: LoopSortKey) => {
    if (sortKey === nextKey) {
      setSortDirection((current) => (current === "asc" ? "desc" : "asc"))
      return
    }

    setSortKey(nextKey)
    setSortDirection(nextKey === "protocol" || nextKey === "asset" ? "asc" : "desc")
  }

  const sortedRows = React.useMemo(() => {
    const direction = sortDirection === "asc" ? 1 : -1
    const parseValue = (value?: string) => {
      if (!value) return Number.NEGATIVE_INFINITY
      const numeric = Number.parseFloat(value.replace(/[^0-9.-]/g, ""))
      return Number.isFinite(numeric) ? numeric : Number.NEGATIVE_INFINITY
    }

    return [...rows].sort((a, b) => {
      switch (sortKey) {
        case "asset":
          return a.asset.localeCompare(b.asset) * direction
        case "apy":
          return (parseValue(a.apy) - parseValue(b.apy)) * direction
        case "rewards":
          return (
            (parseValue(a.rewardRows?.[0]?.value ?? a.partnerRewards) -
              parseValue(b.rewardRows?.[0]?.value ?? b.partnerRewards)) *
            direction
          )
        case "cf":
          return (a.collateralFactor - b.collateralFactor) * direction
        case "capacityFilled":
          return ((a.capacityFilledPct ?? -1) - (b.capacityFilledPct ?? -1)) * direction
        case "points":
          return (parseValue(a.points) - parseValue(b.points)) * direction
        case "protocol":
        default:
          return a.protocol.localeCompare(b.protocol) * direction
      }
    })
  }, [rows, sortDirection, sortKey])

  const sortHeader = (key: LoopSortKey, label: string, hint?: string) => (
    <SortHeaderButton label={label} hint={hint} active={sortKey === key} onClick={() => toggleSort(key)} />
  )

  return (
    <section className="space-y-5">
      {/* Sticky like the Lend spoke headers: each group title hangs under the site
          header while its own table scrolls, then the next group's title takes over. */}
      <div className="sticky top-16 z-20 flex flex-col gap-3 bg-background py-2 md:flex-row md:items-end md:justify-between">
        <div>
          <h2 className="text-[22px] font-normal tracking-[-0.01em] text-foreground dark:text-white md:text-[24px]">
            {t(title)}
          </h2>
        </div>
      </div>

      <DesktopTableSurface className="!rounded-none [contain-intrinsic-size:auto_640px] [content-visibility:auto]">
        <div>
          <ScrollableTable layout={LOOP_TABLE_LAYOUT}>
            <thead>
              <tr className={TABLE_HEADER_ROW}>
                <th className={cn(TABLE_HEADER_CELL, "pl-6 pr-3", TABLE_INDEX_PHONE_HIDDEN)}>#</th>
                <th className={cn(TABLE_HEADER_CELL, "px-4", tableStickyCell("header"))}>
                  {sortHeader(
                    "protocol",
                    t("Loop"),
                    t("The collateral you supply and the asset you borrow against it to build leverage."),
                  )}
                </th>
                <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                  {sortHeader("apy", t("APY"), t("Estimated net yield at maximum leverage, after borrow costs."))}
                </th>
                <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                  {sortHeader("rewards", t("Leverage"), t("The maximum leverage available on this loop."))}
                </th>
                <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                  {sortHeader(
                    "cf",
                    t("CF"),
                    t(
                      "Collateral factor: how much you can borrow per dollar of collateral. LT is the liquidation threshold.",
                    ),
                  )}
                </th>
                <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                  {sortHeader(
                    "capacityFilled",
                    t("Capacity Filled"),
                    t(
                      "Share of supplied funds currently borrowed. Higher usage raises rates and can delay withdrawals.",
                    ),
                  )}
                </th>
                <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                  {sortHeader("points", t("Available"), t("Amount still available to borrow from this market."))}
                </th>
                <th className={cn(TABLE_HEADER_CELL, "px-4 pr-5 text-right")}>
                  <span className="sr-only">{t("Quick actions")}</span>
                </th>
              </tr>
            </thead>
            <tbody key={`${title}-${sortKey}-${sortDirection}`} className="divide-y divide-border dark:divide-white/6">
              {sortedRows.map((row, index) => (
                <LoopTableRow
                  key={`${row.kind}-${row.protocol}-${row.asset}-${row.href}-${index}`}
                  row={row}
                  index={index}
                />
              ))}
              {sortedRows.length === 0 ? (
                <tr>
                  <td
                    className="px-6 py-10 text-[12px] text-muted-foreground dark:text-white/60"
                    colSpan={LOOP_TABLE_LAYOUT.widths.length}
                  >
                    {t("No loops in this category yet.")}
                  </td>
                </tr>
              ) : null}
            </tbody>
          </ScrollableTable>
        </div>
      </DesktopTableSurface>
    </section>
  )
}

// Memoized so an unchanged row doesn't re-render when a sibling row changes (e.g. a
// re-sort or a keystroke that leaves this row's props identical). Props are stable
// references (row) plus a primitive index; hooks are read internally.
const LoopTableRow = React.memo(function LoopTableRow({
  row,
  index,
}: {
  row: MultiplyPageData["lendRows"][number]
  index: number
}) {
  const router = useRouter()
  const { t } = useTranslation()
  const { compact } = useCurrency()
  const hasNegativeApy = isNegativeMultiplyApy(row.apy)

  return (
    <tr
      className={`${TABLE_BODY_ROW} group asset-swap cursor-pointer transition-colors`}
      onClick={() => router.push(row.href)}
      style={{ animationDelay: `${index * 40}ms` }}
    >
      <td className={cn(TABLE_CELL_PADDING_LEADING, TABLE_CELL_INDEX, TABLE_INDEX_PHONE_HIDDEN, TABLE_ROW_HOVER_BG)}>
        {index + 1}
      </td>
      <td className={cn(TABLE_CELL_PADDING, tableStickyCell("body"))}>
        <CellLink href={row.href} className="flex min-w-0 items-center gap-3">
          <PairedLoopIcons collateralSymbol={row.protocol} borrowSymbol={row.asset} eager={index < 2} />
          <span className="min-w-0">
            <span className={cn("block truncate", TABLE_CELL_PRIMARY)}>
              {translateMultiplyLoopSupplyLabel(t, row.protocol)}
            </span>
            <span className={cn("block truncate", TABLE_CELL_SECONDARY)}>
              {translateMultiplyLoopBorrowLabel(t, row.asset)}
            </span>
          </span>
        </CellLink>
      </td>
      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
        <CellLink
          href={row.href}
          className={cn(TABLE_CELL_NUMERIC, "font-data", row.apy ? "" : "text-muted-foreground")}
        >
          {row.apy || "—"}
        </CellLink>
      </td>
      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
        <CellLink href={row.href} className={cn("block font-data", TABLE_CELL_NUMERIC)}>
          {row.rewardRows?.[0]?.value ?? row.partnerRewards ?? "—"}
        </CellLink>
      </td>
      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
        <CellLink href={row.href} className="block">
          <span className={cn("block font-data", TABLE_CELL_NUMERIC)}>{Math.round(row.collateralFactor * 100)}%</span>
          <span className={cn("block font-data tabular-nums", TABLE_CELL_CAPTION)}>
            {t("LT")}: {Math.round(row.liquidationThreshold * 100)}%
          </span>
        </CellLink>
      </td>
      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
        <CellLink href={row.href} className="block">
          <CapacityFilled value={row.capacityFilledPct} />
        </CellLink>
      </td>
      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
        {row.waitlistHref ? (
          <div className="inline-flex items-center">
            <Button asChild size="sm" className="h-6 rounded-xs px-2.5 text-[11px]">
              <a href={row.waitlistHref} target="_blank" rel="noreferrer">
                {t("Join waitlist")}
              </a>
            </Button>
          </div>
        ) : (
          <CellLink href={row.href} className="block text-foreground">
            <span className={cn("block", TABLE_CELL_NUMERIC)}>
              {row.availablePrimary ??
                (parseCompactUsdLabel(row.points) == null
                  ? (row.points ?? "—")
                  : compact(parseCompactUsdLabel(row.points) as number))}
            </span>
            {row.availableSecondary ? (
              <span className={cn("block tabular-nums", TABLE_CELL_SECONDARY)}>
                {parseCompactUsdLabel(row.availableSecondary) == null
                  ? row.availableSecondary
                  : compact(parseCompactUsdLabel(row.availableSecondary) as number)}
              </span>
            ) : null}
          </CellLink>
        )}
      </td>
      <td className={cn(TABLE_CELL_PADDING_TRAILING, "text-right", TABLE_ROW_HOVER_RIGHT)}>
        <HoverActionGroup className="gap-2">
          <Button
            type="button"
            size="table"
            variant={hasNegativeApy ? "table-secondary" : "table-primary"}
            className={TABLE_ACTION_BUTTON}
            title={
              hasNegativeApy
                ? t("Negative net APY: borrow costs exceed supply yield. Review before opening this loop.")
                : undefined
            }
            onClick={(event) => {
              event.stopPropagation()
              const marketId = resolveMarketIdFromHref(row.href)
              if (!marketId) return
              router.push(actionPagePath("multiply", "multiply", { market: marketId, return: row.href }))
            }}
          >
            <ActionIcon label={hasNegativeApy ? "Review risk" : "Multiply"} />
            {t(hasNegativeApy ? "Review risk" : "Multiply")}
          </Button>
        </HoverActionGroup>
      </td>
    </tr>
  )
})

function TrendingLoopCard({
  snapshot,
  interactive = true,
}: {
  snapshot: MultiplyPageData["trendingSnapshots"][number]
  interactive?: boolean
}) {
  const { t } = useTranslation()

  const cardClassName = cn(HIGHLIGHT_CARD_CLASS, "h-[104px] w-[min(372px,calc(100vw-2rem))] p-5")

  const content = (
    <>
      <div className="relative z-10 flex h-full items-center gap-3">
        <TrendingPairedLoopIcons
          collateralSymbol={snapshot.collateralSymbol}
          borrowSymbol={snapshot.borrowSymbol}
          eager
        />

        <div className="min-w-0 flex-1">
          <div className="truncate text-[15px] font-normal tracking-normal text-foreground">
            {translateMultiplyLoopSupplyLabel(t, snapshot.collateralSymbol)}
          </div>
          <div className="mt-1 truncate text-[13px] text-muted-foreground dark:text-white/48">
            {translateMultiplyLoopBorrowLabel(t, snapshot.borrowSymbol)}
          </div>
        </div>

        <div className="shrink-0 text-right">
          <div className="font-data text-[15px] font-normal tracking-normal text-success">{snapshot.apyLabel}</div>
          <div className="mt-1 font-data text-[13px] text-muted-foreground dark:text-white/48">
            {formatTrendingLeverageLabel(snapshot.maxLeverageLabel)}
          </div>
        </div>
      </div>
    </>
  )

  if (!interactive) {
    return (
      <div aria-hidden="true" className={cardClassName}>
        {content}
      </div>
    )
  }

  return (
    <Link href={snapshot.href} className={cardClassName}>
      {content}
    </Link>
  )
}

const TRENDING_BORROW_PX = pairedLoopBorrowPx(TOKEN_ICON_TRENDING_PX)
const TRENDING_CONTAINER_WIDTH_PX = pairedLoopContainerWidthPx(TOKEN_ICON_TRENDING_PX)

function TrendingPairedLoopIcons({
  collateralSymbol,
  borrowSymbol,
  eager = false,
}: {
  collateralSymbol: string
  borrowSymbol: string
  eager?: boolean
}) {
  return (
    <span
      className="relative block shrink-0"
      style={{ height: TOKEN_ICON_TRENDING_PX, width: TRENDING_CONTAINER_WIDTH_PX }}
    >
      <TokenIcon
        symbol={collateralSymbol}
        size="table"
        pixelSize={TOKEN_ICON_TRENDING_PX}
        className="absolute left-0 top-0"
        eager={eager}
      />
      <TokenIcon
        symbol={borrowSymbol}
        size="md"
        pixelSize={TRENDING_BORROW_PX}
        className="absolute bottom-0 right-0 z-10"
        eager={eager}
      />
    </span>
  )
}

function PairedLoopIcons({
  collateralSymbol,
  borrowSymbol,
  eager = false,
}: {
  collateralSymbol: string
  borrowSymbol: string
  eager?: boolean
}) {
  const borrowPx = pairedLoopBorrowPx(TOKEN_ICON_TABLE_PX)

  return (
    <span
      className="relative block shrink-0"
      style={{ height: TOKEN_ICON_TABLE_PX, width: TOKEN_ICON_TABLE_PAIR_WIDTH_PX }}
    >
      <TokenIcon symbol={collateralSymbol} size="table" className="absolute left-0 top-0" eager={eager} />
      <TokenIcon
        symbol={borrowSymbol}
        size="md"
        pixelSize={borrowPx}
        className="absolute bottom-0 right-0 z-10"
        eager={eager}
      />
    </span>
  )
}

function CellLink({ href, className, children }: { href: string; className?: string; children: React.ReactNode }) {
  return (
    <Link href={href} className={cn("block text-left", className)}>
      {children}
    </Link>
  )
}
