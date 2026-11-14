"use client"

import { useMemo, useState } from "react"
import { useRouter } from "next/navigation"
import { TokenBubble } from "@/app/borrow/components/atoms"
import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import { ArrowUpRight } from "@/app/components/icons"
import { DesktopTableSurface, HoverActionGroup, SilentActionHeader } from "@/app/components/market-table-primitives"
import { Button } from "@/components/ui/button"
import type { AssetDetail } from "@/app/lib/borrow-detail"
import { resolveCollateralForAsset } from "@/app/lib/borrow-detail/cross-market"
import { borrowMarketDetailPath } from "@/app/lib/borrow-routes"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { TABLE_ROW_HOVER_BG, TABLE_ROW_HOVER_LEFT, TABLE_ROW_HOVER_RIGHT } from "@/app/lib/ui/table-row-hover"
import { cn } from "@/lib/utils"

type Props = { detail: AssetDetail; id?: string }
type SortKey = "pool" | "cf" | "allocation"

function SortIcon() {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 12 16"
      fill="none"
      className="size-[14px] text-muted-foreground/70 dark:text-white/60"
    >
      <path d="M4 5 6 3l2 2" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M4 11 6 13l2-2" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

function headerButtonClass(active: boolean) {
  return cn(
    "flex items-center gap-2 transition-colors",
    active ? "text-foreground dark:text-white" : "text-muted-foreground dark:text-white/42",
  )
}

function headerCellClass(extra?: string) {
  return cn(
    "bg-table-header px-4 pb-2 pt-2.5 text-[11px] font-medium uppercase tracking-[0.08em] text-muted-foreground dark:text-white/58",
    extra,
  )
}

function poolIdFromAllocationRow(assetId: string, rowId: string) {
  const prefix = `${assetId}-`
  return rowId.startsWith(prefix) ? rowId.slice(prefix.length) : rowId
}

function marketHrefForAllocationRow(assetId: string, rowId: string) {
  return borrowMarketDetailPath(poolIdFromAllocationRow(assetId, rowId))
}

function ViewDetailButton({ href, label }: { href: string; label: string }) {
  const router = useRouter()
  return (
    <HoverActionGroup className="gap-2">
      <Button
        type="button"
        size="table"
        variant="table-secondary"
        className="w-auto"
        onClick={(event) => {
          event.stopPropagation()
          router.push(href)
        }}
      >
        <ArrowUpRight className="size-3.5" aria-hidden />
        {label}
      </Button>
    </HoverActionGroup>
  )
}

export function AllocationBreakdownCard({ detail, id }: Props) {
  const { t } = useTranslation()
  const { compact } = useCurrency()
  const router = useRouter()
  const [sortKey, setSortKey] = useState<SortKey>("allocation")
  const [sortDirection, setSortDirection] = useState<"asc" | "desc">("desc")

  const helpText = t("Assets that can be used as collateral to borrow {symbol} from this market.").replace(
    "{symbol}",
    detail.hero.symbol,
  )

  const collateralFactorByPoolId = useMemo(() => {
    const map = new Map<string, number>()
    for (const market of resolveCollateralForAsset(detail.row)) {
      map.set(market.id, market.collateralFactorPct)
    }
    // Prefer Convex-hydrated CF on allocation rows when present.
    for (const row of detail.allocation) {
      if (row.collateralFactorPct === undefined) continue
      const poolId = poolIdFromAllocationRow(detail.row.id, row.id)
      map.set(poolId, row.collateralFactorPct)
    }
    return map
  }, [detail.allocation, detail.row])

  const rows = useMemo(() => {
    const direction = sortDirection === "asc" ? 1 : -1
    return [...detail.allocation]
      .map((row) => {
        const poolId = poolIdFromAllocationRow(detail.row.id, row.id)
        return {
          ...row,
          poolId,
          href: marketHrefForAllocationRow(detail.row.id, row.id),
          collateralFactorPct: collateralFactorByPoolId.get(poolId) ?? 0,
        }
      })
      .sort((a, b) => {
        switch (sortKey) {
          case "cf":
            return (a.collateralFactorPct - b.collateralFactorPct) * direction
          case "allocation":
            return (a.sharePct - b.sharePct) * direction
          case "pool":
          default:
            return a.poolName.localeCompare(b.poolName) * direction
        }
      })
  }, [collateralFactorByPoolId, detail.allocation, detail.row.id, sortDirection, sortKey])

  const toggleSort = (nextKey: SortKey) => {
    if (sortKey === nextKey) {
      setSortDirection((current) => (current === "asc" ? "desc" : "asc"))
      return
    }
    setSortKey(nextKey)
    setSortDirection(nextKey === "pool" ? "asc" : "desc")
  }

  return (
    <section id={id} aria-label={t("Supported Collateral")} className="space-y-5">
      <div className="flex items-center gap-1.5">
        <h2 className="text-[22px] font-medium tracking-[-0.01em] text-foreground dark:text-white md:text-[24px]">
          {t("Supported Collateral")}
        </h2>
        <ActionMetricHelp text={helpText} topic="Supported Collateral" />
      </div>

      {rows.length === 0 ? (
        <p className="text-[13px] text-muted-foreground dark:text-white/44">
          {t("No pools currently expose {symbol} as a borrow asset.").replace("{symbol}", detail.hero.symbol)}
        </p>
      ) : (
        <DesktopTableSurface className="!rounded-none">
          <div className="overflow-x-auto md:overflow-x-visible">
            <table className="w-full min-w-[640px] table-fixed border-separate border-spacing-0 text-[12px] md:min-w-0">
              <colgroup>
                <col className="w-[6%]" />
                <col className="w-[42%]" />
                <col className="w-[20%]" />
                <col className="w-[16%]" />
                <col className="w-[16%]" />
              </colgroup>
              <thead>
                <tr className="bg-table-header text-left text-muted-foreground">
                  <th className={headerCellClass("pl-4 pr-2 sm:pl-6")}>#</th>
                  <th className={headerCellClass("px-2 sm:px-4")}>
                    <button
                      type="button"
                      onClick={() => toggleSort("pool")}
                      className={headerButtonClass(sortKey === "pool")}
                    >
                      <span>{t("ASSET")}</span>
                      <SortIcon />
                    </button>
                  </th>
                  <th className={headerCellClass("px-2 sm:px-4")}>
                    <button
                      type="button"
                      onClick={() => toggleSort("cf")}
                      className={headerButtonClass(sortKey === "cf")}
                    >
                      <span>{t("COLLATERAL FACTOR")}</span>
                      <SortIcon />
                    </button>
                  </th>
                  <th className={headerCellClass("px-2 sm:px-4")}>
                    <button
                      type="button"
                      onClick={() => toggleSort("allocation")}
                      className={headerButtonClass(sortKey === "allocation")}
                    >
                      <span>{t("ALLOCATION")}</span>
                      <SortIcon />
                    </button>
                  </th>
                  <SilentActionHeader className="pr-4 sm:pr-6" />
                </tr>
              </thead>
              <tbody className="divide-y divide-border dark:divide-white/6">
                {rows.map((row, index) => (
                  <tr
                    key={row.id}
                    className="group cursor-pointer transition-colors"
                    onClick={() => router.push(row.href)}
                  >
                    <td
                      className={`py-2.5 pl-4 pr-2 align-middle font-data text-[14px] font-medium tabular-nums text-muted-foreground dark:text-white/52 sm:pl-6 ${TABLE_ROW_HOVER_LEFT}`}
                    >
                      {index + 1}
                    </td>
                    <td className={`min-w-0 py-2.5 px-2 sm:px-4 ${TABLE_ROW_HOVER_BG}`}>
                      <div className="flex min-w-0 items-center gap-3">
                        <div className="flex shrink-0 items-center">
                          <span className="relative z-[1]">
                            <TokenBubble visual={row.visuals[0]} size="table" ring={false} className="bg-transparent" />
                          </span>
                          <span className="-ml-3">
                            <TokenBubble visual={row.visuals[1]} size="table" ring={false} className="bg-transparent" />
                          </span>
                        </div>
                        <div className="min-w-0">
                          <div className="truncate text-[15px] font-medium tracking-normal text-foreground dark:text-white">
                            {row.poolName}
                          </div>
                          <div className="mt-1 truncate text-[13px] font-normal tracking-normal tabular-nums text-muted-foreground dark:text-white/38">
                            {row.feeTier ? `${row.feeTier} · ` : ""}
                            {row.tvlUsd !== undefined ? `${compact(row.tvlUsd)} ${t("TVL")}` : ""}
                          </div>
                        </div>
                      </div>
                    </td>
                    <td
                      className={`py-2.5 px-2 font-data text-[15px] font-normal tracking-normal tabular-nums text-foreground dark:text-white sm:px-4 ${TABLE_ROW_HOVER_BG}`}
                    >
                      {Math.round(row.collateralFactorPct)}%
                    </td>
                    <td
                      className={`py-2.5 px-2 font-data text-[15px] font-normal tracking-normal tabular-nums text-foreground dark:text-white sm:px-4 ${TABLE_ROW_HOVER_BG}`}
                    >
                      {row.sharePct.toFixed(2)}%
                    </td>
                    <td className={`py-2.5 pl-2 pr-4 text-right sm:pr-6 ${TABLE_ROW_HOVER_RIGHT}`}>
                      <ViewDetailButton href={row.href} label={t("View")} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </DesktopTableSurface>
      )}
    </section>
  )
}
