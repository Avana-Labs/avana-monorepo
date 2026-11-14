"use client"

import Image from "next/image"
import { ActionIcon } from "@/app/components/action-icon"
import { CapacityFilled } from "@/app/components/capacity-filled"
import { useRouter, useSearchParams } from "next/navigation"
import { useEffect, useMemo, useRef, useState } from "react"
import { Button } from "@/components/ui/button"
import {
  DesktopTableSurface,
  HoverActionGroup,
  ScrollableTable,
  SortHeaderButton,
} from "@/app/components/market-table-primitives"
import { TokenIcon } from "@/app/components/token-icon"
import type { LendPageData } from "@/app/lib/data/providers/lend"
import { cn } from "@/lib/utils"
import {
  TABLE_ACTION_BUTTON,
  TABLE_BODY_ROW,
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
import { TokenTickerPriceLabel } from "@/app/lib/ui/token-ticker-price-label"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { MarketFiltersBar, MarketFiltersEmptyState } from "@/app/lib/ui/market-filters"
import {
  EMPTY_MARKET_FILTERS,
  LEND_MARKET_OPTIONS,
  buildAssetOptions,
  lendFilterItem,
  matchesMarketFilters,
  type MarketFilterState,
} from "@/app/lib/markets/filters"

const isLendCategory = (value: string) => LEND_MARKET_OPTIONS.some((option) => option.id === value)
import { useCurrency } from "@/app/lib/currency/use-currency"
import { RevealSentinel, useProgressiveReveal } from "@/app/lib/ui/use-progressive-reveal"
import { redenominateCompactUsd } from "@/app/lib/currency/format"
import { sizedLocalIconSrc } from "@/app/lib/local-asset-icons"

type AssetRow = LendPageData["assetGroups"][number]["rows"][number] & {
  marketId?: string
  href?: string
  supplyApyLabel?: string
  rewardsApyLabel?: string
  totalApyLabel?: string
  supplyApyValue?: number
  rewardsApyValue?: number
  totalDepositsLabel?: string
  totalDepositsSecondaryLabel?: string
  totalDepositsSortValue?: number
  utilizationLabel?: string
  utilizationValue?: number
  availableLiquidityLabel?: string
  availableLiquiditySecondaryLabel?: string
  availableLiquiditySortValue?: number
}
type AssetGroup = LendPageData["assetGroups"][number]
const LEND_PAGE_SIZE = 12

/**
 * Sort each group's rows by the table's default order (asset name) BEFORE the progressive reveal
 * slices them. Slicing unsorted rows and letting the table sort them put newly revealed rows above
 * rows already on screen, so the list jumped as it grew.
 */
export function orderLendGroupsForReveal(groups: AssetGroup[]): AssetGroup[] {
  return groups.map((group) => ({ ...group, rows: [...group.rows].sort((a, b) => a.name.localeCompare(b.name)) }))
}

export function paginateLendAssetGroups(groups: AssetGroup[], page: number, pageSize = LEND_PAGE_SIZE) {
  const start = Math.max(0, page) * pageSize
  const end = start + pageSize
  let cursor = 0
  return groups
    .map((group) => {
      const groupStart = cursor
      const groupEnd = cursor + group.rows.length
      cursor = groupEnd
      const sliceStart = Math.max(0, start - groupStart)
      const sliceEnd = Math.min(group.rows.length, end - groupStart)
      return { ...group, rows: sliceEnd > sliceStart ? group.rows.slice(sliceStart, sliceEnd) : [] }
    })
    .filter((group) => group.rows.length > 0)
}
const DEFAULT_ASSET_GROUPS: AssetGroup[] = []

function AssetIcon({ row, eager = false }: { row: AssetRow; eager?: boolean }) {
  if (row.logoSrc) {
    return (
      <span className="relative flex size-12 shrink-0 items-center justify-center bg-transparent">
        <Image
          alt={row.logoAlt ?? `${row.symbol} logo`}
          src={sizedLocalIconSrc(row.logoSrc, 48)}
          width={48}
          height={48}
          sizes="48px"
          className="h-full w-full object-contain"
          loading={eager ? "eager" : "lazy"}
          fetchPriority={eager ? "high" : undefined}
          unoptimized
        />
      </span>
    )
  }

  return <TokenIcon symbol={row.symbol} size="table" eager={eager} />
}

function AssetRowView({
  row,
  index,
  delay,
  onDeposit,
}: {
  row: AssetRow
  index: number
  delay: number
  onDeposit?: (marketId: string) => void
}) {
  const { t } = useTranslation()
  const { ctx } = useCurrency()
  const router = useRouter()
  const marketId = "marketId" in row && typeof row.marketId === "string" ? row.marketId : row.symbol.toLowerCase()
  const detailHref = row.href ?? `/lend/markets/${marketId}`
  return (
    <tr
      className={`${TABLE_BODY_ROW} asset-swap group cursor-pointer transition-colors`}
      style={{ animationDelay: `${delay}ms` }}
      onClick={() => router.push(detailHref)}
    >
      <td className={cn(TABLE_CELL_PADDING_LEADING, TABLE_CELL_INDEX, TABLE_INDEX_PHONE_HIDDEN, TABLE_ROW_HOVER_BG)}>
        {index + 1}
      </td>
      <td className={cn(TABLE_CELL_PADDING, tableStickyCell("body"))}>
        <div className="flex min-w-0 items-center gap-3">
          <AssetIcon row={row} eager={index < 2} />
          <div className="min-w-0">
            <div className={cn("truncate", TABLE_CELL_PRIMARY)}>{row.name}</div>
            <div className={cn("truncate", TABLE_CELL_SECONDARY)}>
              <TokenTickerPriceLabel symbol={row.symbol} />
            </div>
          </div>
        </div>
      </td>

      <td className={cn(TABLE_CELL_PADDING, TABLE_CELL_NUMERIC, TABLE_ROW_HOVER_BG)}>
        {row.supplyApyLabel ?? row.apy}
      </td>

      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
        <div className={TABLE_CELL_NUMERIC}>{row.totalDepositsLabel ?? row.totalDepositsPrimary}</div>
        <div className={cn(TABLE_CELL_SECONDARY, "tabular-nums")}>
          {redenominateCompactUsd(row.totalDepositsSecondaryLabel ?? row.totalDepositsSecondary, ctx)}
        </div>
      </td>

      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
        <CapacityFilled value={row.utilizationValue === undefined ? undefined : row.utilizationValue * 100} />
      </td>

      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
        <div className={TABLE_CELL_NUMERIC}>{row.availableLiquidityLabel ?? row.availableLiquidityPrimary}</div>
        <div className={cn(TABLE_CELL_SECONDARY, "tabular-nums")}>
          {redenominateCompactUsd(row.availableLiquiditySecondaryLabel ?? row.availableLiquiditySecondary, ctx)}
        </div>
      </td>

      <td
        className={cn(TABLE_CELL_PADDING_TRAILING, "text-right", TABLE_ROW_HOVER_RIGHT)}
        onClick={(event) => event.stopPropagation()}
      >
        {onDeposit ? (
          <HoverActionGroup className="gap-2">
            <Button
              type="button"
              size="table"
              variant="table-primary"
              className={TABLE_ACTION_BUTTON}
              onClick={(e) => {
                e.stopPropagation()
                onDeposit(marketId)
              }}
            >
              <ActionIcon label="Deposit" />
              {t("Deposit")}
            </Button>
          </HoverActionGroup>
        ) : null}
      </td>
    </tr>
  )
}

const LEND_TABLE_LAYOUT = tableColumnLayout([
  "index",
  "identity",
  "compact", // APY
  "metric", // Total deposits
  "gauge", // Capacity filled
  "metric", // Available
  "action",
])

function AssetSection({
  title,
  subtitle,
  rows,
  onDeposit,
  deferContent,
}: {
  title: string
  subtitle?: string
  rows: AssetRow[]
  onDeposit?: (marketId: string) => void
  deferContent: boolean
}) {
  const { t } = useTranslation()
  const sectionRef = useRef<HTMLElement | null>(null)
  const [contentMounted, setContentMounted] = useState(!deferContent || process.env.NODE_ENV === "test")
  const [sortKey, setSortKey] = useState<
    "asset" | "supplyApy" | "totalDeposits" | "utilization" | "availableLiquidity"
  >("asset")
  const [sortDirection, setSortDirection] = useState<"asc" | "desc">("asc")

  const toggleSort = (nextKey: typeof sortKey) => {
    if (sortKey === nextKey) {
      setSortDirection((current) => (current === "asc" ? "desc" : "asc"))
      return
    }

    setSortKey(nextKey)
    setSortDirection(nextKey === "asset" ? "asc" : "desc")
  }

  const sortedRows = useMemo(() => {
    const direction = sortDirection === "asc" ? 1 : -1

    return [...rows].sort((a, b) => {
      switch (sortKey) {
        case "supplyApy":
          return ((a.supplyApyValue ?? a.apyValue / 100) - (b.supplyApyValue ?? b.apyValue / 100)) * direction
        case "totalDeposits":
          return (
            ((a.totalDepositsSortValue ?? a.totalDepositsValue ?? 0) -
              (b.totalDepositsSortValue ?? b.totalDepositsValue ?? 0)) *
            direction
          )
        case "utilization":
          return ((a.utilizationValue ?? 0) - (b.utilizationValue ?? 0)) * direction
        case "availableLiquidity":
          return (
            ((a.availableLiquiditySortValue ?? a.availableLiquidityValue ?? 0) -
              (b.availableLiquiditySortValue ?? b.availableLiquidityValue ?? 0)) *
            direction
          )
        case "asset":
        default:
          return a.name.localeCompare(b.name) * direction
      }
    })
  }, [rows, sortDirection, sortKey])

  const sortHeader = (key: typeof sortKey, label: string, hint?: string) => (
    <SortHeaderButton label={label} hint={hint} active={sortKey === key} onClick={() => toggleSort(key)} />
  )

  useEffect(() => {
    if (contentMounted) return
    const section = sectionRef.current
    if (!section || typeof IntersectionObserver === "undefined") {
      setContentMounted(true)
      return
    }
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (!entry?.isIntersecting) return
        setContentMounted(true)
        observer.disconnect()
      },
      { rootMargin: "400px 0px", threshold: 0 },
    )
    observer.observe(section)
    return () => observer.disconnect()
  }, [contentMounted])

  return (
    <section ref={sectionRef} className="space-y-5">
      {/* Sticky like the Borrow spoke headers: each asset-group title hangs under the
          site header while its own table scrolls, then the next group's title takes over. */}
      <div className="sticky top-16 z-20 flex flex-col gap-3 bg-background py-2 md:flex-row md:items-end md:justify-between">
        <div>
          <h2
            className={cn(
              "text-[22px] font-normal tracking-[-0.01em] text-foreground dark:text-white md:text-[24px]",
              title === "Ethereum-Based" ? "md:text-[23px]" : "",
            )}
          >
            {t(title)}
          </h2>
          {subtitle ? <p className="mt-1 text-[13px] text-muted-foreground dark:text-white/44">{t(subtitle)}</p> : null}
        </div>
      </div>

      {!contentMounted ? (
        <div aria-hidden className="min-h-[640px] rounded-radius-md bg-table-row" />
      ) : (
        <DesktopTableSurface className="!rounded-none [contain-intrinsic-size:auto_640px] [content-visibility:auto]">
          <ScrollableTable layout={LEND_TABLE_LAYOUT}>
            <thead>
              <tr className={TABLE_HEADER_ROW}>
                <th className={cn(TABLE_HEADER_CELL, "pl-6 pr-3", TABLE_INDEX_PHONE_HIDDEN)}>#</th>
                <th className={cn(TABLE_HEADER_CELL, "px-4", tableStickyCell("header"))}>
                  {sortHeader("asset", t("Asset"), t("The token you can supply to earn yield."))}
                </th>
                <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                  {sortHeader("supplyApy", t("APY"), t("Annual percentage yield you earn by supplying this asset."))}
                </th>
                <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                  {sortHeader(
                    "totalDeposits",
                    t("Total Deposits"),
                    t("Total amount supplied to this market by all users."),
                  )}
                </th>
                <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                  {sortHeader(
                    "utilization",
                    t("Capacity Filled"),
                    t(
                      "Share of supplied funds currently borrowed. Higher usage raises rates and can delay withdrawals.",
                    ),
                  )}
                </th>
                <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                  {sortHeader(
                    "availableLiquidity",
                    t("Available"),
                    t("Funds not currently borrowed, available to withdraw or borrow."),
                  )}
                </th>
                <th className={cn(TABLE_HEADER_CELL, "px-4 pr-5 text-right")}>
                  {/* Names the action column for screen readers (an empty <th> isn't a header). */}
                  <span className="sr-only">{t("Quick actions")}</span>
                </th>
              </tr>
            </thead>
            <tbody key={`${title}-${sortKey}-${sortDirection}`} className="divide-y divide-border dark:divide-white/6">
              {sortedRows.length > 0 ? (
                sortedRows.map((row, index) => (
                  <AssetRowView key={row.symbol} row={row} index={index} delay={index * 40} onDeposit={onDeposit} />
                ))
              ) : (
                <tr>
                  <td
                    className="px-6 py-10 text-[12px] text-muted-foreground dark:text-white/60"
                    colSpan={LEND_TABLE_LAYOUT.widths.length}
                  >
                    {t("No assets match these filters.")}
                  </td>
                </tr>
              )}
            </tbody>
          </ScrollableTable>
        </DesktopTableSurface>
      )}
    </section>
  )
}

export function LendAssetSpokes({
  groups = DEFAULT_ASSET_GROUPS,
  onDeposit,
}: {
  groups?: LendPageData["assetGroups"]
  onDeposit?: (marketId: string) => void
}) {
  const { t } = useTranslation()
  const searchParams = useSearchParams()
  const [search, setSearch] = useState("")
  // Deep links (e.g. the header mega-menu's "View all") can preselect a Markets category via ?category=.
  const [filters, setFilters] = useState<MarketFilterState>(() => {
    const param = searchParams?.get("category")
    return { ...EMPTY_MARKET_FILTERS, markets: param && isLendCategory(param) ? [param] : [] }
  })

  // Deep links from the header mega-menu ("View all") keep the Markets filter in sync when the
  // query changes on this same page; the #markets hash on the link handles scrolling here.
  const categoryParam = searchParams?.get("category")
  useEffect(() => {
    if (categoryParam && isLendCategory(categoryParam)) {
      setFilters((current) => ({ ...current, markets: [categoryParam] }))
    }
  }, [categoryParam])

  const allRows = useMemo(() => groups.flatMap((group) => group.rows), [groups])
  const filterItems = useMemo(() => allRows.map((row) => lendFilterItem(row.symbol)), [allRows])
  const assetOptions = useMemo(() => buildAssetOptions(allRows), [allRows])

  const filteredGroups = useMemo(() => {
    const query = search.trim().toLowerCase()

    const filtered = groups
      .map((group) => {
        const rows = group.rows.filter((row) => {
          const matchesSearch =
            query.length === 0 || row.name.toLowerCase().includes(query) || row.symbol.toLowerCase().includes(query)
          return matchesSearch && matchesMarketFilters(lendFilterItem(row.symbol), filters)
        })

        return { ...group, rows }
      })
      .filter((group) => group.rows.length > 0)
    return orderLendGroupsForReveal(filtered)
  }, [groups, search, filters])
  const totalRows = filteredGroups.reduce((sum, group) => sum + group.rows.length, 0)

  // Reveal assets on scroll instead of paginating: only the first chunk of rows
  // (sliced across the ordered groups) renders up front, then the sentinel eases
  // in the rest as the user scrolls down.
  const { visibleCount, hasMore, isRevealing, sentinelRef } = useProgressiveReveal({
    total: totalRows,
    chunkSize: LEND_PAGE_SIZE,
    resetKey: `${JSON.stringify(filters)}|${search.trim().toLowerCase()}`,
  })
  const revealedGroups = useMemo(
    () => paginateLendAssetGroups(filteredGroups, 0, visibleCount),
    [filteredGroups, visibleCount],
  )

  return (
    <section
      id="markets"
      className="mt-6 scroll-mt-24 space-y-8 sm:mt-[38px] sm:space-y-[58px]"
      style={{ overflowAnchor: "none" }}
    >
      <div className="py-2.5">
        <MarketFiltersBar
          items={filterItems}
          value={filters}
          onChange={setFilters}
          marketOptions={LEND_MARKET_OPTIONS}
          assetOptions={assetOptions}
          search={search}
          onSearchChange={setSearch}
          searchPlaceholder={t("Search assets")}
        />
      </div>

      {/* At least one screen tall, so narrowing the filters never shortens the page enough to
          force the browser to pull the scroll position back. */}
      <div className="min-h-[100svh] space-y-14">
        {revealedGroups.length > 0 ? (
          revealedGroups.map((group, index) => (
            <div key={group.title} className="space-y-8">
              <AssetSection
                title={group.title}
                subtitle={group.subtitle}
                rows={group.rows}
                onDeposit={onDeposit}
                deferContent={index > 0}
              />
              {group.title === "Ethereum-Based" ? (
                <div className="flex justify-center">
                  <div className="h-px w-full max-w-[980px] bg-gradient-to-r from-transparent via-border/80 to-transparent dark:via-white/10" />
                </div>
              ) : null}
            </div>
          ))
        ) : (
          <MarketFiltersEmptyState
            message={t("No assets match these filters.")}
            onClear={() => {
              setFilters(EMPTY_MARKET_FILTERS)
              setSearch("")
            }}
          />
        )}
      </div>

      {hasMore ? <RevealSentinel sentinelRef={sentinelRef} active={isRevealing} /> : null}
    </section>
  )
}
