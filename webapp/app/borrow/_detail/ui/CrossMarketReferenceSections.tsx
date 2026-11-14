"use client"

import { useMemo, useState } from "react"
import { useRouter } from "next/navigation"
import { TokenBubble } from "@/app/borrow/components/atoms"
import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import { ArrowUpRight } from "@/app/components/icons"
import { DesktopTableSurface, HoverActionGroup, SilentActionHeader } from "@/app/components/market-table-primitives"
import { Button } from "@/components/ui/button"
import type { BorrowableAssetRef } from "@/app/lib/borrow-detail/cross-market"
import { formatApy } from "@/app/lib/format"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { TABLE_ROW_HOVER_BG, TABLE_ROW_HOVER_LEFT, TABLE_ROW_HOVER_RIGHT } from "@/app/lib/ui/table-row-hover"
import { cn } from "@/lib/utils"

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

export function AssetsYouCanBorrowSection({
  collateralLabel,
  assets,
}: {
  collateralLabel: string
  assets: BorrowableAssetRef[]
}) {
  const { t } = useTranslation()
  const { compact } = useCurrency()
  const router = useRouter()
  const [sortKey, setSortKey] = useState<"asset" | "apy">("asset")
  const [sortDirection, setSortDirection] = useState<"asc" | "desc">("asc")

  const rows = useMemo(() => {
    const direction = sortDirection === "asc" ? 1 : -1
    return [...assets].sort((a, b) => {
      if (sortKey === "apy") return (a.apy - b.apy) * direction
      return a.name.localeCompare(b.name) * direction
    })
  }, [assets, sortDirection, sortKey])

  const toggleSort = (nextKey: "asset" | "apy") => {
    if (sortKey === nextKey) {
      setSortDirection((current) => (current === "asc" ? "desc" : "asc"))
      return
    }
    setSortKey(nextKey)
    setSortDirection(nextKey === "apy" ? "desc" : "asc")
  }

  if (assets.length === 0) return null

  const helpText = t("What assets can be borrowed with {name} as collateral.").replace("{name}", collateralLabel)

  return (
    <section aria-label={t("Assets You Can Borrow")} className="space-y-5">
      <div className="flex items-center gap-1.5">
        <h2 className="text-[22px] font-medium tracking-[-0.01em] text-foreground dark:text-white md:text-[24px]">
          {t("Assets You Can Borrow")}
        </h2>
        <ActionMetricHelp text={helpText} topic="Assets You Can Borrow" />
      </div>

      <DesktopTableSurface className="!rounded-none">
        <div className="overflow-x-auto">
          <table className="w-full table-fixed border-separate border-spacing-0 text-[12px]">
            <colgroup>
              <col className="w-[6%]" />
              <col className="w-[46%]" />
              <col className="w-[22%]" />
              <col className="w-[26%]" />
            </colgroup>
            <thead>
              <tr className="bg-table-header text-left text-muted-foreground">
                <th className={headerCellClass("pl-6 pr-3")}>#</th>
                <th className={headerCellClass()}>
                  <button
                    type="button"
                    onClick={() => toggleSort("asset")}
                    className={headerButtonClass(sortKey === "asset")}
                  >
                    <span>{t("ASSET")}</span>
                    <SortIcon />
                  </button>
                </th>
                <th className={headerCellClass()}>
                  <button
                    type="button"
                    onClick={() => toggleSort("apy")}
                    className={headerButtonClass(sortKey === "apy")}
                  >
                    <span>{t("APY")}</span>
                    <SortIcon />
                  </button>
                </th>
                <SilentActionHeader className="pr-6" />
              </tr>
            </thead>
            <tbody className="divide-y divide-border dark:divide-white/6">
              {rows.map((asset, index) => (
                <tr
                  key={asset.id}
                  className="group cursor-pointer transition-colors"
                  onClick={() => router.push(asset.href)}
                >
                  <td
                    className={`py-2.5 pl-6 pr-3 align-middle font-data text-[14px] font-medium tabular-nums text-muted-foreground dark:text-white/52 ${TABLE_ROW_HOVER_LEFT}`}
                  >
                    {index + 1}
                  </td>
                  <td className={`py-2.5 px-4 ${TABLE_ROW_HOVER_BG}`}>
                    <div className="flex min-w-0 items-center gap-4">
                      <TokenBubble visual={asset.visual} size="table" ring={false} className="bg-transparent" />
                      <div className="min-w-0">
                        <div className="truncate text-[15px] font-medium tracking-normal text-foreground dark:text-white">
                          {asset.name}
                        </div>
                        <div className="mt-0.5 truncate text-[13px] font-normal tracking-normal tabular-nums text-muted-foreground dark:text-white/38">
                          {formatApy(asset.apy)}
                          {asset.tvlUsd !== undefined ? ` · ${compact(asset.tvlUsd)} ${t("Supply")}` : ""}
                        </div>
                      </div>
                    </div>
                  </td>
                  <td
                    className={`py-2.5 px-4 font-data text-[15px] font-normal tracking-normal tabular-nums text-foreground dark:text-white ${TABLE_ROW_HOVER_BG}`}
                  >
                    <span className="tabular-nums">{formatApy(asset.apy)}</span>
                  </td>
                  <td className={`py-2.5 px-4 pr-6 text-right ${TABLE_ROW_HOVER_RIGHT}`}>
                    <ViewDetailButton href={asset.href} label={t("View")} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </DesktopTableSurface>
    </section>
  )
}
