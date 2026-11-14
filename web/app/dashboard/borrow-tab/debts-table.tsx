"use client"

import { useMemo } from "react"
import { LiveInterestOwedUsd } from "@/app/dashboard/live-accrual"
import { useCanonicalPriceFor } from "@/app/lib/prices/token-prices-context"
import { borrowAssetDetailPath } from "@/app/lib/borrow-routes"
import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import { TableHeaderHint } from "@/app/components/table-header-hint"
import { DASHBOARD_SNAPSHOT_SURFACE_CLASS } from "@/app/components/card-surface-tokens"
import { ActionIcon } from "@/app/components/action-icon"
import { useRouter } from "next/navigation"
import { Button } from "@/components/ui/button"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { formatTokenQuantity } from "@/app/lib/currency/format"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { LIQUIDATION_LTV } from "@/app/lib/data/borrow-domain"
import type { DebtRowContext } from "@/app/lib/data/borrow-position-types"
import { TokenIcon } from "@/app/components/token-icon"
import {} from "@/app/components/market-card-primitives"
import { DesktopTableSurface, HoverActionGroup, ScrollableTable } from "@/app/components/market-table-primitives"
import { liqUtilizationBarClass, liqUtilizationPercentTextClass } from "@/app/lib/borrow-system/liq-utilization-tone"
import { cn } from "@/lib/utils"

import { formatSectionCount } from "@/app/lib/ui/section-count"
import {
  DASHBOARD_TABLE_REFERENCE_PX,
  TABLE_ACTION_BUTTON,
  TABLE_BODY_ROW,
  TABLE_CELL_NUMERIC,
  TABLE_CELL_PADDING,
  TABLE_CELL_PADDING_TRAILING,
  TABLE_CELL_PRIMARY,
  TABLE_CELL_SECONDARY,
  TABLE_HEADER_CELL,
  TABLE_HEADER_ROW,
  TABLE_ROW_HOVER_BG,
  TABLE_ROW_HOVER_RIGHT,
  tableColumnLayout,
  tableStickyCell,
  formatTableHeaderLabel,
} from "@/app/lib/ui/table-row-hover"

type DebtsTableProps = {
  rows: DebtRowContext[]
  totals: {
    totalBorrowed: number
    totalCollateral: number
    averageHf: number | null
    accruedInterest: number
    dailyInterest: number
  }
  onRepay: (context: DebtRowContext) => void
  showBalance?: boolean
  showSummary?: boolean
  showHeading?: boolean
}

const MASK = "••••"

function DebtsMetricHeader({ label, help, align = "left" }: { label: string; help: string; align?: "left" | "right" }) {
  return (
    <TableHeaderHint hint={help} className={cn("inline-flex items-center gap-1", align === "right" && "justify-end")}>
      {formatTableHeaderLabel(label)}
    </TableHeaderHint>
  )
}

/**
 * Interest owed, ticking in real time — the debt mirror of the My Deposits APY cell's earned
 * counter. Big line is the borrow rate; this small line accrues `borrowed × APR` on top of the
 * interest already owed, in red. The anchor resets whenever the accrued base refreshes so the
 * live tick never double-counts what the ledger has already booked.
 */
function OwedCell({ row, show, className }: { row: DebtRowContext; show: boolean; className?: string }) {
  const baseUsd = row.accruedInterestUsd
  const anchorMs = useMemo(() => Date.now(), [baseUsd])
  if (!show) return <span className={className}>{MASK}</span>
  return (
    <span className={className}>
      +
      <LiveInterestOwedUsd
        anchorMs={anchorMs}
        ratePerYearUsd={(row.borrowedUsd * row.borrowApr) / 100}
        baseUsd={baseUsd}
        fractionDigits={4}
      />
    </span>
  )
}
const TICK_COUNT = 28

const DEBTS_LAYOUT = tableColumnLayout(
  [
    "identityCompact", // Debt asset + collateral pool
    "metric", // Borrowed
    "metric", // Borrow APR + owed
    "actionCompact", // Repay
  ],
  { referenceWidth: DASHBOARD_TABLE_REFERENCE_PX },
)

export function DebtsPanel({
  rows,
  totals,
  onRepay,
  showBalance = true,
  showSummary = true,
  showHeading = true,
}: DebtsTableProps) {
  const { t } = useTranslation()
  const router = useRouter()
  const { exact } = useCurrency()
  const priceFor = useCanonicalPriceFor()
  const m = (value: string) => (showBalance ? value : MASK)
  return (
    <section className="mb-2">
      {showSummary ? (
        <CurrentLtvCard
          borrowedUsd={totals.totalBorrowed}
          collateralUsd={totals.totalCollateral}
          showBalance={showBalance}
          dailyInterestUsd={totals.dailyInterest}
          accruedInterestUsd={totals.accruedInterest}
        />
      ) : null}
      {showHeading ? (
        <div className="mb-3">
          <h3 className="text-[18px] font-medium tracking-tight text-foreground md:text-[20px]">{t("My Debts")}</h3>
          <p className="mt-1 text-[13px] text-muted-foreground">{formatSectionCount(rows.length, "loan", "loans")}</p>
        </div>
      ) : null}
      {rows.length === 0 ? (
        <div className="rounded-radius-md border border-dashed border-border px-6 py-10 text-center text-[13px] text-muted-foreground">
          {t("No active loans. Borrow against your collateral to get started.")}
        </div>
      ) : (
        <>
          <DesktopTableSurface className="!rounded-none">
            <ScrollableTable layout={DEBTS_LAYOUT}>
              <thead>
                <tr className={TABLE_HEADER_ROW}>
                  <th className={cn(TABLE_HEADER_CELL, "px-4", tableStickyCell("header"))}>
                    <DebtsMetricHeader
                      label={t("Debt")}
                      help={t("The asset you've borrowed against your collateral.")}
                    />
                  </th>
                  <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                    <DebtsMetricHeader
                      label={t("Borrowed")}
                      help={t("Your outstanding loan balance in this asset, valued live.")}
                    />
                  </th>
                  <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                    <DebtsMetricHeader
                      label={t("Borrow APR")}
                      help={t(
                        "The current annual borrow rate on this debt. Below, the interest accrued so far, ticking live.",
                      )}
                    />
                  </th>
                  <th className={cn(TABLE_HEADER_CELL, "px-4 pr-5 text-right")}>
                    <span className="sr-only">{t("Repay")}</span>
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border dark:divide-white/6">
                {rows.map((row) => {
                  // A debt row is the borrowed asset, so it opens the asset detail page (not the
                  // collateral pool market); fall back to the pool only when the asset id is absent.
                  const detailHref = row.debtAssetId
                    ? borrowAssetDetailPath(row.debtAssetId)
                    : `/borrow/markets/${row.pool.id}`
                  const debtSymbol = row.debtAssetSymbol
                  // `borrowedUsd` is a USD amount (currentDebtValueUsd6). The primary line is the
                  // token quantity owed — USD ÷ live price — and the secondary line is that USD
                  // value, mirroring the My Deposits "Deposited" column. Never render the USD
                  // amount as a token count, and never multiply a *Usd field by price again.
                  const debtPrice = priceFor(debtSymbol)
                  const debtTokenQty = debtPrice != null && debtPrice > 0 ? row.borrowedUsd / debtPrice : null
                  return (
                    <tr
                      key={row.id ?? row.pool.id}
                      className={`${TABLE_BODY_ROW} group cursor-pointer transition-colors`}
                      onClick={() => router.push(detailHref)}
                    >
                      <td className={cn(TABLE_CELL_PADDING, "pl-6", tableStickyCell("body"))}>
                        {/* Debt is a single borrowed token, not the collateral LP pool — show the
                            borrowed asset, with the collateral market as context. */}
                        <div className="flex min-w-0 items-center gap-3">
                          <TokenIcon symbol={debtSymbol} size="table" />
                          <div className="min-w-0">
                            <div className={cn("truncate", TABLE_CELL_PRIMARY)}>{debtSymbol}</div>
                            <div className={cn("truncate", TABLE_CELL_SECONDARY)}>
                              {t("against {pool}").replace("{pool}", row.pool.name)}
                            </div>
                          </div>
                        </div>
                      </td>
                      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
                        <div className={TABLE_CELL_NUMERIC}>
                          {showBalance
                            ? debtTokenQty != null
                              ? formatTokenQuantity(debtTokenQty, debtSymbol)
                              : exact(row.borrowedUsd)
                            : MASK}
                        </div>
                        <div className={TABLE_CELL_SECONDARY}>
                          {debtTokenQty != null ? m(exact(row.borrowedUsd)) : null}
                        </div>
                      </td>
                      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
                        <div className={TABLE_CELL_NUMERIC}>{row.borrowApr.toFixed(2)}%</div>
                        <OwedCell row={row} show={showBalance} className={cn(TABLE_CELL_SECONDARY, "text-rose-500")} />
                      </td>
                      <td className={cn(TABLE_CELL_PADDING_TRAILING, "text-right", TABLE_ROW_HOVER_RIGHT)}>
                        <HoverActionGroup className="gap-2">
                          <Button
                            type="button"
                            size="table"
                            variant="table-primary"
                            className={TABLE_ACTION_BUTTON}
                            onClick={(event) => {
                              event.stopPropagation()
                              onRepay(row)
                            }}
                          >
                            <ActionIcon label="Repay" />
                            {t("Repay")}
                          </Button>
                        </HoverActionGroup>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </ScrollableTable>
          </DesktopTableSurface>
        </>
      )}
    </section>
  )
}

export function CurrentLtvCard({
  borrowedUsd,
  collateralUsd,
  showBalance,
  dailyInterestUsd,
  accruedInterestUsd,
}: {
  borrowedUsd: number
  collateralUsd: number
  showBalance: boolean
  // Borrowing cost. Optional so callers that only have the LTV inputs (multiply
  // health card) render the card unchanged; the borrow tab passes both.
  dailyInterestUsd?: number
  accruedInterestUsd?: number
}) {
  const { t } = useTranslation()
  const { compact, exact } = useCurrency()
  const masked = !showBalance
  // With no collateral AND no debt there is no position to assess. Treat this as
  // a neutral/empty state rather than letting the "0 borrowing power" branch read
  // as RISK for a wallet that simply hasn't opened anything.
  const hasPosition = collateralUsd > 0 || borrowedUsd > 0
  const liquidationValueUsd = collateralUsd * LIQUIDATION_LTV
  const remainingBorrowingPowerUsd = Math.max(0, liquidationValueUsd - borrowedUsd)
  const liqUtilizationPct = liquidationValueUsd > 0 ? Math.min(100, (borrowedUsd / liquidationValueUsd) * 100) : 0
  const barFillPct = liquidationValueUsd > 0 ? liqUtilizationPct : 0
  const borrowingPowerLabel = masked ? "••" : compact(remainingBorrowingPowerUsd)
  const usedLabel = masked ? "••" : compact(borrowedUsd)
  const maxLabel = masked ? "••" : compact(liquidationValueUsd)
  const usedTicks = Math.max(1, Math.round((barFillPct / 100) * TICK_COUNT))
  const tone = liqUtilizationBarClass(liqUtilizationPct)
  const liqPercentTone = liqUtilizationPercentTextClass(liqUtilizationPct)
  const statusLabel = !hasPosition ? t("NONE") : remainingBorrowingPowerUsd > 0 ? t("GOOD") : t("RISK")
  const statusToneClass = hasPosition ? "bg-emerald-500/10 text-success" : "bg-muted text-muted-foreground"

  return (
    <div className={`${DASHBOARD_SNAPSHOT_SURFACE_CLASS} px-5 py-4 md:px-6 md:py-5`}>
      <div className="flex h-6 items-center justify-between gap-3">
        <div className="flex min-w-0 items-baseline gap-2">
          <span className="font-data text-[20px] font-normal leading-none tracking-tight text-foreground">
            {borrowingPowerLabel}
          </span>
          <span className="text-[13px] font-normal text-foreground">{t("Borrowing Power")}</span>
          <ActionMetricHelp
            topic="Borrowing Power"
            text={t(
              "Remaining room to borrow before your position approaches liquidation, based on current collateral and outstanding debt.",
            )}
          />
        </div>
        <span
          className={`inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide ${statusToneClass}`}
        >
          {statusLabel}
        </span>
      </div>

      <div className="relative mt-9">
        <div
          className="pointer-events-none absolute bottom-full z-10 -translate-x-1/2 pb-1 text-center"
          style={{ left: `${barFillPct}%` }}
        >
          <div className="rounded-md bg-foreground px-1.5 py-0.5 font-data text-[11px] font-normal text-background">
            {masked ? "••" : `${liqUtilizationPct.toFixed(1)}%`}
          </div>
          <div className="-mt-px text-[10px] leading-none text-foreground">▼</div>
        </div>

        <div className="flex h-8 w-full items-end gap-[3px]">
          {Array.from({ length: TICK_COUNT }).map((_, index) => {
            const cls = index < usedTicks ? tone : "bg-muted"
            const isCurrent = index === Math.max(0, usedTicks - 1)
            return (
              <span
                key={index}
                className={cn(
                  "flex-1 rounded-xs transition-all",
                  isCurrent ? "h-full ring-2 ring-foreground ring-offset-1 ring-offset-surface-inset" : "h-[75%]",
                  cls,
                )}
              />
            )
          })}
        </div>
      </div>

      <div className="mt-2.5 flex items-center justify-between text-[11px] font-medium text-muted-foreground">
        <span>
          {t("Used")} <span className="font-normal text-foreground">{usedLabel}</span>
        </span>
        <span className="inline-flex items-center gap-2">
          <span>
            {t("Liq. max")} <span className="font-normal text-foreground">{maxLabel}</span>
          </span>
          <span className={liqPercentTone}>
            {masked ? "••" : t("{percent}% of liq. max").replace("{percent}", liqUtilizationPct.toFixed(0))}
          </span>
        </span>
      </div>

      {dailyInterestUsd != null || accruedInterestUsd != null ? (
        <div className="mt-3 flex items-center justify-between border-t border-border pt-3 text-[11px] font-medium text-muted-foreground">
          <span>
            {t("Interest / day")}{" "}
            <span className="font-normal text-rose-500">{masked ? "••" : exact(dailyInterestUsd ?? 0)}</span>
          </span>
          <span>
            {t("Accrued interest")}{" "}
            <span className="font-normal text-foreground">{masked ? "••" : exact(accruedInterestUsd ?? 0)}</span>
          </span>
        </div>
      ) : null}
    </div>
  )
}
