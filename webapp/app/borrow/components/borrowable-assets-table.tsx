"use client"

import { memo, useMemo, useState } from "react"
import Link from "next/link"
import { ActionIcon } from "@/app/components/action-icon"
import { CapacityFilled } from "@/app/components/capacity-filled"
import { useRouter } from "next/navigation"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { formatTokenQuantity } from "@/app/lib/currency/format"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import {
  DesktopTableSurface,
  HoverActionGroup,
  ScrollableTable,
  SortHeaderButton,
} from "@/app/components/market-table-primitives"
import type { BorrowableAsset } from "@/app/lib/data/borrow-domain"
import { borrowAssetDetailPath } from "@/app/lib/borrow-routes"
import { TokenBubble } from "./atoms"
import { useCanonicalPriceFor } from "@/app/lib/prices/token-prices-context"
import { cn } from "@/lib/utils"
import { TickerPriceFlip } from "@/app/lib/ui/token-ticker-price-label"
import { Button } from "@/components/ui/button"

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

type BorrowableAssetsTableProps = {
  rows: BorrowableAsset[]
  onBorrow: (asset: BorrowableAsset) => void
}

export function BorrowableAssetsPanel({ rows, onBorrow }: BorrowableAssetsTableProps) {
  const { t } = useTranslation()
  if (rows.length === 0) {
    return (
      <div className="rounded-radius-md border border-dashed border-border bg-surface-raised/50 px-6 py-10 text-center text-[13px] text-muted-foreground">
        {t("No assets match your filter.")}
      </div>
    )
  }

  return <LoanAssetsSection assets={rows} onBorrow={onBorrow} embedded />
}

// Memoized loan-variant row: reads price via the reactive `useCanonicalPriceFor` hook
// and pulls router/currency/translation from hooks internally, so the only props are
// stable (asset, index, onBorrow) and React.memo can skip unchanged rows.
const LoanAssetsRow = memo(function LoanAssetsRow({
  asset,
  index,
  onBorrow,
}: {
  asset: BorrowableAsset
  index: number
  onBorrow: (asset: BorrowableAsset) => void
}) {
  const priceFor = useCanonicalPriceFor()
  const router = useRouter()
  const { compact } = useCurrency()
  const { t } = useTranslation()
  return (
    <tr
      className={`${TABLE_BODY_ROW} group cursor-pointer transition-colors`}
      onClick={() => router.push(borrowAssetDetailPath(asset.id))}
    >
      <td className={cn(TABLE_CELL_PADDING_LEADING, TABLE_CELL_INDEX, TABLE_INDEX_PHONE_HIDDEN, TABLE_ROW_HOVER_BG)}>
        {index + 1}
      </td>
      <td className={cn(TABLE_CELL_PADDING, tableStickyCell("body"))}>
        {/* Real anchor on the primary cell: crawlable, copyable, and keyboard-focusable (Enter
            navigates natively). stopPropagation keeps the row's own onClick from double-firing. */}
        <Link
          href={borrowAssetDetailPath(asset.id)}
          onClick={(event) => event.stopPropagation()}
          className="flex min-w-0 items-center gap-4 rounded-radius-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
        >
          <TokenBubble visual={asset.visual} size="table" ring={false} className="bg-transparent" eager={index < 2} />
          <div className="min-w-0">
            <div className={cn("truncate", TABLE_CELL_PRIMARY)}>{asset.name}</div>
            <div className={cn("truncate tabular-nums", TABLE_CELL_SECONDARY)}>
              <TickerPriceFlip
                symbol={asset.symbol}
                detail={`${compact(asset.totalBorrowedUsd + asset.availableUsd)} ${t("Supply")}`}
              />
            </div>
          </div>
        </Link>
      </td>
      <td className={cn(TABLE_CELL_PADDING, TABLE_CELL_NUMERIC, TABLE_ROW_HOVER_BG)}>{asset.borrowApr.toFixed(2)}%</td>
      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
        <div className={TABLE_CELL_NUMERIC}>
          {formatTokenQuantity(asset.totalBorrowedUsd / (priceFor(asset.symbol) ?? 1), asset.symbol)}
        </div>
        <div className={cn(TABLE_CELL_SECONDARY, "tabular-nums")}>{compact(asset.totalBorrowedUsd)}</div>
      </td>
      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
        <CapacityFilled value={asset.utilization} />
      </td>
      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
        <div className={TABLE_CELL_NUMERIC}>
          {formatTokenQuantity(asset.availableUsd / (priceFor(asset.symbol) ?? 1), asset.symbol)}
        </div>
        <div className={cn(TABLE_CELL_SECONDARY, "tabular-nums")}>{compact(asset.availableUsd)}</div>
      </td>
      <td className={cn(TABLE_CELL_PADDING_TRAILING, "text-right", TABLE_ROW_HOVER_RIGHT)}>
        <HoverActionGroup className="gap-2">
          <Button
            type="button"
            size="table"
            variant="table-secondary"
            className={TABLE_ACTION_BUTTON}
            onClick={(event) => {
              event.stopPropagation()
              onBorrow(asset)
            }}
          >
            <ActionIcon label="Borrow" />
            {t("Borrow")}
          </Button>
        </HoverActionGroup>
      </td>
    </tr>
  )
})

const LOAN_TABLE_LAYOUT = tableColumnLayout([
  "index",
  "identity",
  "compact", // Borrow APR
  "metric", // Total borrows
  "gauge", // Capacity filled
  "metric", // Available
  "action",
])

function LoanAssetsSection({
  assets,
  onBorrow,
  embedded = false,
}: {
  assets: BorrowableAsset[]
  onBorrow: (asset: BorrowableAsset) => void
  embedded?: boolean
}) {
  const [sortKey, setSortKey] = useState<"asset" | "apy" | "borrows" | "capacityFilled" | "liquidity">("asset")
  const [sortDirection, setSortDirection] = useState<"asc" | "desc">("asc")
  const { t } = useTranslation()

  const toggleSort = (nextKey: typeof sortKey) => {
    if (sortKey === nextKey) {
      setSortDirection((current) => (current === "asc" ? "desc" : "asc"))
      return
    }

    setSortKey(nextKey)
    setSortDirection(nextKey === "asset" ? "asc" : "desc")
  }

  const sortedAssets = useMemo(() => {
    const direction = sortDirection === "asc" ? 1 : -1

    return [...assets].sort((a, b) => {
      switch (sortKey) {
        case "apy":
          return (a.borrowApr - b.borrowApr) * direction
        case "borrows":
          return (a.totalBorrowedUsd - b.totalBorrowedUsd) * direction
        case "capacityFilled":
          return (a.utilization - b.utilization) * direction
        case "liquidity":
          return (a.availableUsd - b.availableUsd) * direction
        case "asset":
        default:
          return a.name.localeCompare(b.name) * direction
      }
    })
  }, [assets, sortDirection, sortKey])

  const sortHeader = (key: typeof sortKey, label: string, hint?: string) => (
    <SortHeaderButton label={label} hint={hint} active={sortKey === key} onClick={() => toggleSort(key)} />
  )

  const table = (
    <ScrollableTable layout={LOAN_TABLE_LAYOUT}>
      <thead>
        <tr className={TABLE_HEADER_ROW}>
          <th className={cn(TABLE_HEADER_CELL, "pl-6 pr-3", TABLE_INDEX_PHONE_HIDDEN)}>#</th>
          <th className={cn(TABLE_HEADER_CELL, "px-4", tableStickyCell("header"))}>
            {sortHeader("asset", t("Asset"), t("The token you can borrow against your collateral."))}
          </th>
          <th className={cn(TABLE_HEADER_CELL, "px-4")}>
            {sortHeader(
              "apy",
              t("Borrow APR"),
              t("Annual interest rate you pay on borrowed funds. It moves with utilization."),
            )}
          </th>
          <th className={cn(TABLE_HEADER_CELL, "px-4")}>
            {sortHeader(
              "borrows",
              t("Total Borrows"),
              t("Total amount currently borrowed from this market by all users."),
            )}
          </th>
          <th className={cn(TABLE_HEADER_CELL, "px-4")}>
            {sortHeader(
              "capacityFilled",
              t("Capacity Filled"),
              t("Share of supplied funds currently borrowed. Higher usage raises rates and can delay withdrawals."),
            )}
          </th>
          <th className={cn(TABLE_HEADER_CELL, "px-4")}>
            {sortHeader("liquidity", t("Available"), t("Amount still available to borrow from this market."))}
          </th>
          <th className={cn(TABLE_HEADER_CELL, "px-4 pr-5 text-right")}>
            <span className="sr-only">{t("Quick actions")}</span>
          </th>
        </tr>
      </thead>

      <tbody key={`loan-${sortKey}-${sortDirection}-${sortedAssets.length}`}>
        {sortedAssets.map((asset, index) => (
          <LoanAssetsRow key={asset.id} asset={asset} index={index} onBorrow={onBorrow} />
        ))}
      </tbody>
    </ScrollableTable>
  )

  if (embedded) {
    return table
  }

  return (
    <section className="space-y-5">
      <DesktopTableSurface>{table}</DesktopTableSurface>
    </section>
  )
}
