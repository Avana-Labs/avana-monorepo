"use client"

import { memo, useEffect, useMemo, useRef, useState } from "react"
import Link from "next/link"
import { ActionIcon } from "@/app/components/action-icon"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import {
  DesktopTableSurface,
  HoverActionGroup,
  ScrollableTable,
  SortHeaderButton,
} from "@/app/components/market-table-primitives"
import {
  formatRiskPremium,
  type BorrowPoolRow,
  type BorrowSpoke,
  type BorrowableAsset,
  type DexGroup,
  type PendingMarketRow,
} from "@/app/lib/data/borrow-domain"
import { borrowMarketDetailPath } from "@/app/lib/borrow-routes"
import { formatBorrowPairLabel, formatLtvPct } from "@/app/lib/borrow-market-rows"
import { liquidationThresholdPctFromMaxLtvPct } from "@/app/lib/borrow-system/liquidation-threshold"
import { BorrowableAssetsPanel } from "./borrowable-assets-table"
import { TokenBubble } from "./atoms"
import { formatApy } from "@/app/lib/format"
import { cn } from "@/lib/utils"
import { HoverFlip } from "@/app/lib/ui/token-ticker-price-label"
import { Button } from "@/components/ui/button"
import { CapacityFilled } from "@/app/components/capacity-filled"

import {
  TABLE_ACTION_BUTTON,
  TABLE_BODY_ROW,
  TABLE_CELL_CAPTION,
  TABLE_CELL_INDEX,
  TABLE_CELL_NUMERIC,
  TABLE_CELL_PADDING,
  TABLE_CELL_PADDING_LEADING,
  TABLE_CELL_PADDING_TRAILING,
  TABLE_HEADER_CELL,
  TABLE_HEADER_ROW,
  TABLE_INDEX_PHONE_HIDDEN,
  TABLE_ROW_HOVER_BG,
  TABLE_ROW_HOVER_RIGHT,
  tableColumnLayout,
  tableStickyCell,
} from "@/app/lib/ui/table-row-hover"

type CollateralPoolsTableProps = {
  groups: ReadonlyArray<DexGroup>
  borrowAssetsBySpoke: Readonly<Record<string, BorrowableAsset[]>>
  pending?: ReadonlyArray<PendingMarketRow>
  onViewMarket: (pool: BorrowPoolRow) => void
  onUseAsCollateral: (pool: BorrowPoolRow) => void
  /** Borrowable-tab row action (the workspace picks the desktop or phone behaviour). */
  onBorrowAsset: (asset: BorrowableAsset) => void
}

type SectionTabId = "collateral" | "borrow"

function SectionTabs({
  activeTab,
  onTabChange,
}: {
  activeTab: SectionTabId
  onTabChange: (tab: SectionTabId) => void
}) {
  const { t } = useTranslation()
  return (
    <div className="flex flex-wrap gap-8 border-b border-border/50 md:border-b-0">
      {[
        // UI labels only. The tab `id`s are the backend/routing terms and MUST stay
        // "collateral" / "borrow": the "collateral" tab lists the LP *markets* (see
        // CollateralDesktopTable) and the "borrow" tab lists the *borrowable* assets
        // (see BorrowableAssetsPanel / borrowAssetsBySpoke). If you're looking for the
        // "Borrowable" assets, that's the `id: "borrow"` tab below.
        { id: "collateral", label: t("Collateral") },
        { id: "borrow", label: t("Borrowable") },
      ].map((tab) => (
        <button
          key={tab.id}
          type="button"
          onClick={() => onTabChange(tab.id as SectionTabId)}
          className={[
            "border-b-2 pb-2 text-left text-[15px] font-normal tracking-normal transition-colors md:text-[17px]",
            activeTab === tab.id
              ? "border-foreground text-foreground"
              : "border-transparent text-muted-foreground hover:text-foreground",
          ].join(" ")}
        >
          {tab.label}
        </button>
      ))}
    </div>
  )
}

function CollateralAssetCell({ pool }: { pool: BorrowPoolRow }) {
  const { compact } = useCurrency()
  const { t } = useTranslation()
  // Sub-label: TVL, flipping to the risk premium on desktop row hover (the premium has no column
  // of its own). Phones show both on one line.
  const tvl = `${compact(pool.tvlUsd)} ${t("TVL")}`
  const premium = `${t("Premium")}: ${formatRiskPremium(pool.riskPremiumBps)}`
  return (
    <div className="flex min-w-0 items-center gap-4 max-md:gap-2">
      <div className="flex shrink-0 items-center">
        <span className="relative z-[1]">
          <TokenBubble visual={pool.visuals[0]} size="table" ring={false} className="bg-transparent" />
        </span>
        <span className="-ml-3">
          <TokenBubble visual={pool.visuals[1]} size="table" ring={false} className="bg-transparent" />
        </span>
      </div>
      <div className="min-w-0">
        <div className="truncate text-[15px] font-normal tracking-normal text-foreground dark:text-white">
          {formatBorrowPairLabel(pool)}
        </div>
        <div className="mt-1 truncate text-[13px] font-normal tracking-normal text-muted-foreground dark:text-white/38">
          <HoverFlip front={tvl} back={premium} touch={`${tvl} · ${premium}`} />
        </div>
      </div>
    </div>
  )
}

// Borrow pools store a single risk ratio (max LTV, which is the collateral factor). The
// liquidation threshold sits a fixed spread above it — derive the display LT through the
// canonical helper so it matches the credit engine's enforced threshold. This lets the CF
// column read like the multiply table's (CF on top, small "LT:" below).
function poolLiquidationThresholdPct(pool: BorrowPoolRow) {
  return liquidationThresholdPctFromMaxLtvPct(pool.ltv)
}

// Memoized pool row: router/currency/translation are read from hooks internally, so the
// props are stable references (pool, callbacks) plus a primitive index, letting
// React.memo skip rows whose data hasn't changed when a sibling row updates.
const CollateralPoolRow = memo(function CollateralPoolRow({
  pool,
  index,
  onViewMarket,
  onUseAsCollateral,
}: {
  pool: BorrowPoolRow
  index: number
  onViewMarket: (pool: BorrowPoolRow) => void
  onUseAsCollateral?: (pool: BorrowPoolRow) => void
}) {
  const { compact } = useCurrency()
  const { t } = useTranslation()
  return (
    <tr className={`${TABLE_BODY_ROW} group cursor-pointer transition-colors`} onClick={() => onViewMarket(pool)}>
      <td className={cn(TABLE_CELL_PADDING_LEADING, TABLE_CELL_INDEX, TABLE_INDEX_PHONE_HIDDEN, TABLE_ROW_HOVER_BG)}>
        {index + 1}
      </td>
      <td className={cn(TABLE_CELL_PADDING, tableStickyCell("body"))}>
        {/* Real anchor on the primary cell: crawlable, copyable, and keyboard-focusable (Enter
            navigates natively). stopPropagation keeps the row's own onClick from double-firing. */}
        <Link
          href={borrowMarketDetailPath(pool.id)}
          onClick={(event) => event.stopPropagation()}
          className="block rounded-radius-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
        >
          <CollateralAssetCell pool={pool} />
        </Link>
      </td>
      <td className={cn(TABLE_CELL_PADDING, TABLE_CELL_NUMERIC, TABLE_ROW_HOVER_BG)}>
        {formatApy((pool.aprMin + pool.aprMax) / 2)}
      </td>
      <td className={cn(TABLE_CELL_PADDING, TABLE_CELL_NUMERIC, TABLE_ROW_HOVER_BG)}>{compact(pool.tvlUsd)}</td>
      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
        <div className={cn(TABLE_CELL_NUMERIC, "font-data")}>{formatLtvPct(pool.ltv)}</div>
        <div className={cn(TABLE_CELL_CAPTION, "font-data tabular-nums")}>
          {t("LT")}: {formatLtvPct(poolLiquidationThresholdPct(pool))}
        </div>
      </td>
      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
        <CapacityFilled value={pool.capacityFilledPct} />
      </td>
      <td className={cn(TABLE_CELL_PADDING_TRAILING, "text-right", TABLE_ROW_HOVER_RIGHT)}>
        <HoverActionGroup className="gap-2">
          {onUseAsCollateral ? (
            <Button
              type="button"
              size="table"
              variant="table-primary"
              className={TABLE_ACTION_BUTTON}
              onClick={(event) => {
                event.stopPropagation()
                onUseAsCollateral(pool)
              }}
            >
              <ActionIcon label="Pledge" />
              {t("Pledge")}
            </Button>
          ) : null}
        </HoverActionGroup>
      </td>
    </tr>
  )
})

const COLLATERAL_TABLE_LAYOUT = tableColumnLayout([
  "index",
  "identity",
  "compact", // Pool APR
  "metric", // Total deposits
  "compact", // Max LTV
  "gauge", // Capacity filled
  "action",
])

function CollateralDesktopTable({
  rows,
  pending,
  onViewMarket,
  onUseAsCollateral,
  embedded = false,
}: {
  rows: ReadonlyArray<BorrowPoolRow>
  pending: ReadonlyArray<PendingMarketRow>
  onViewMarket: (pool: BorrowPoolRow) => void
  onUseAsCollateral?: (pool: BorrowPoolRow) => void
  embedded?: boolean
}) {
  const { t } = useTranslation()
  const [sortKey, setSortKey] = useState<"asset" | "apy" | "deposits" | "cf" | "capacityFilled">("asset")
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
        case "apy":
          return ((a.aprMin + a.aprMax) / 2 - (b.aprMin + b.aprMax) / 2) * direction
        case "cf":
          return (a.ltv - b.ltv) * direction
        case "deposits":
          return (a.tvlUsd - b.tvlUsd) * direction
        case "capacityFilled":
          return ((a.capacityFilledPct ?? -1) - (b.capacityFilledPct ?? -1)) * direction
        case "asset":
        default:
          return (
            `${a.visuals[0].symbol}/${a.visuals[1].symbol}`.localeCompare(
              `${b.visuals[0].symbol}/${b.visuals[1].symbol}`,
            ) * direction
          )
      }
    })
  }, [rows, sortDirection, sortKey])

  const sortHeader = (key: typeof sortKey, label: string, hint?: string) => (
    <SortHeaderButton label={label} hint={hint} active={sortKey === key} onClick={() => toggleSort(key)} />
  )

  const table = (
    <ScrollableTable layout={COLLATERAL_TABLE_LAYOUT}>
      <thead>
        <tr className={TABLE_HEADER_ROW}>
          <th className={cn(TABLE_HEADER_CELL, "pl-6 pr-3", TABLE_INDEX_PHONE_HIDDEN)}>#</th>
          <th className={cn(TABLE_HEADER_CELL, "px-4", tableStickyCell("header"))}>
            {sortHeader("asset", t("Asset"), t("The liquidity pool you can pledge as collateral to borrow against."))}
          </th>
          <th className={cn(TABLE_HEADER_CELL, "px-4")}>
            {sortHeader("apy", t("Pool APR"), t("Annual trading-fee yield earned by this liquidity pool."))}
          </th>
          <th className={cn(TABLE_HEADER_CELL, "px-4")}>
            {sortHeader(
              "deposits",
              t("Total Deposits"),
              t("Total value of LP positions pledged to this market by all users."),
            )}
          </th>
          <th className={cn(TABLE_HEADER_CELL, "px-4")}>
            {sortHeader("cf", t("Max LTV"), t("The most you can borrow as a share of your collateral value."))}
          </th>
          <th className={cn(TABLE_HEADER_CELL, "px-4")}>
            {sortHeader(
              "capacityFilled",
              t("Capacity Filled"),
              t("Share of supplied funds currently borrowed. Higher usage raises rates and can delay withdrawals."),
            )}
          </th>
          <th className={cn(TABLE_HEADER_CELL, "px-4 pr-5 text-right")}>
            <span className="sr-only">{t("Quick actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody key={`collateral-${sortKey}-${sortDirection}-${sortedRows.length}`}>
        {sortedRows.map((pool, index) => (
          <CollateralPoolRow
            key={pool.id}
            pool={pool}
            index={index}
            onViewMarket={onViewMarket}
            onUseAsCollateral={onUseAsCollateral}
          />
        ))}
        {pending.map((row) => (
          <tr key={row.id}>
            <td
              className="px-6 py-2.5 text-[12px] text-muted-foreground"
              colSpan={COLLATERAL_TABLE_LAYOUT.widths.length}
            >
              {row.label}
              <span className="ml-2 text-[12px] text-muted-foreground">· {row.subLabel}</span>
            </td>
          </tr>
        ))}
      </tbody>
    </ScrollableTable>
  )

  if (embedded) {
    return table
  }

  return <DesktopTableSurface>{table}</DesktopTableSurface>
}

export const CollateralPoolsTable = memo(function CollateralPoolsTable({
  groups,
  borrowAssetsBySpoke,
  pending = [],
  onViewMarket,
  onUseAsCollateral,
  onBorrowAsset,
}: CollateralPoolsTableProps) {
  const spokes = groups.flatMap((group) => group.spokes)

  return (
    <div className="space-y-10">
      {spokes.map((entry, index) => (
        <SpokeDesktopSection
          key={entry.spoke.id}
          spoke={entry.spoke}
          rows={entry.rows}
          borrowAssets={borrowAssetsBySpoke[entry.spoke.id] ?? []}
          pending={pending.filter((row) => row.spoke === entry.spoke.id)}
          onViewMarket={onViewMarket}
          onUseAsCollateral={onUseAsCollateral}
          onBorrowAsset={onBorrowAsset}
          deferContent={index > 0}
        />
      ))}
    </div>
  )
})

function SpokeDesktopSection({
  spoke,
  rows,
  borrowAssets,
  pending,
  onViewMarket,
  onUseAsCollateral,
  onBorrowAsset,
  deferContent,
}: {
  spoke: BorrowSpoke
  rows: BorrowPoolRow[]
  borrowAssets: BorrowableAsset[]
  pending: PendingMarketRow[]
  onViewMarket: (pool: BorrowPoolRow) => void
  onUseAsCollateral: (pool: BorrowPoolRow) => void
  onBorrowAsset: (asset: BorrowableAsset) => void
  deferContent: boolean
}) {
  // Each spoke/category owns its own Collateral/Borrowable toggle.
  const [activeTab, setActiveTab] = useState<SectionTabId>("collateral")
  const [contentMounted, setContentMounted] = useState(!deferContent)
  const sectionRef = useRef<HTMLElement | null>(null)

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
  // NOTE: no `overflow-hidden` / `cv-section` here — both would trap the sticky
  // section header. The header below is `sticky top-16` so each spoke title (+ its
  // Collateral/Borrowable tabs) hangs under the site header while its own table
  // scrolls, then the next spoke's header takes over.
  return (
    <section ref={sectionRef} className="mb-2">
      <div className="mt-4 rounded-radius-xl bg-transparent md:shadow-none">
        <div className="sticky top-16 z-20 flex items-center justify-between gap-3 rounded-t-radius-xl bg-background py-2 md:py-3">
          <SectionTabs
            activeTab={activeTab}
            onTabChange={(tab) => {
              setContentMounted(true)
              setActiveTab(tab)
            }}
          />
          {/* Phones: title first (left), tabs on the right; desktop: tabs left, title right. */}
          <h3 className="min-w-0 truncate text-[16px] font-normal tracking-[-0.01em] text-foreground max-md:order-first dark:text-white md:text-[24px]">
            {spoke.label}
          </h3>
        </div>
        <div className="bg-transparent">
          {!contentMounted ? (
            <div
              aria-hidden
              className="min-h-[360px] rounded-radius-md bg-table-row"
              data-testid="deferred-spoke-content"
            />
          ) : activeTab === "collateral" ? (
            <CollateralDesktopTable
              rows={rows}
              pending={pending}
              onViewMarket={onViewMarket}
              onUseAsCollateral={onUseAsCollateral}
              embedded
            />
          ) : (
            <BorrowableAssetsPanel rows={borrowAssets} onBorrow={onBorrowAsset} />
          )}
        </div>
      </div>
    </section>
  )
}
