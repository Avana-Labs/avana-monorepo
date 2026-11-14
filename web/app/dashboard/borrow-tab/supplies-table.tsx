"use client"

import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import { TableHeaderHint } from "@/app/components/table-header-hint"
import { DASHBOARD_SNAPSHOT_SURFACE_CLASS } from "@/app/components/card-surface-tokens"
import { useRouter } from "next/navigation"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { formatHealthFactor, healthFactorToneClass, homeVisualToBorrowVisual } from "@/app/lib/data/borrow-domain"
import type { SupplyRowContext } from "@/app/lib/data/borrow-position-types"
import {
  HF_ZONES,
  activeHealthFactorZoneIndex,
  healthFactorStatusLabel,
} from "@/app/lib/action-system/health-factor-ui"
import { HfNumber, TokenPairCell } from "@/app/borrow/components/atoms"
import {
  DesktopTableSurface,
  ROW_OPEN_ARROW_CLASS,
  RowOpenArrowIcon,
  ScrollableTable,
} from "@/app/components/market-table-primitives"
import {} from "@/app/components/market-card-primitives"
import { HealthFactorPositionBar } from "@/app/components/action-page/action-health-factor-bar"
import { formatApy } from "@/app/lib/format"
import { liqUtilizationPercentTextClass } from "@/app/lib/borrow-system/liq-utilization-tone"
import { formatBorrowMarketContext } from "@/app/lib/borrow-system/market-labels"
import { formatSectionCount } from "@/app/lib/ui/section-count"
import { cn } from "@/lib/utils"
import {
  DASHBOARD_TABLE_REFERENCE_PX,
  TABLE_BODY_ROW,
  TABLE_CELL_CAPTION,
  TABLE_CELL_NUMERIC,
  TABLE_CELL_PADDING,
  TABLE_CELL_PADDING_TRAILING,
  TABLE_HEADER_CELL,
  TABLE_HEADER_ROW,
  TABLE_ROW_HOVER_BG,
  TABLE_ROW_HOVER_RIGHT,
  formatTableHeaderLabel,
  tableColumnLayout,
  tableStickyCell,
} from "@/app/lib/ui/table-row-hover"

const SUPPLIES_LAYOUT = tableColumnLayout(
  [
    "identityCompact", // LP pair + venue
    "compact", // Value + LP APR
    "metric", // Borrow power + % used
    "metric", // HF + liquidation value
    "arrow",
  ],
  { referenceWidth: DASHBOARD_TABLE_REFERENCE_PX },
)

type SuppliesTableProps = {
  rows: SupplyRowContext[]
  totals: { collateral: number; borrowed: number; available: number; fees: number; averageHf: number | null }
  showBalance?: boolean
  showSummary?: boolean
  showHeading?: boolean
}

const MASK = "••••"

function SuppliesMetricHeader({
  label,
  help,
  align = "left",
}: {
  label: string
  help: string
  align?: "left" | "right"
}) {
  return (
    <TableHeaderHint hint={help} className={cn("inline-flex items-center gap-1", align === "right" && "justify-end")}>
      {formatTableHeaderLabel(label)}
    </TableHeaderHint>
  )
}

export function SuppliesPanel({
  rows,
  totals,
  showBalance = true,
  showSummary = true,
  showHeading = true,
}: SuppliesTableProps) {
  const { t } = useTranslation()
  const router = useRouter()
  const { compact, exact } = useCurrency()
  const m = (value: string) => (showBalance ? value : MASK)
  return (
    <section className="mb-2">
      {showSummary ? (
        <SuppliesHealthFactorCard averageHealthFactor={totals.averageHf} showBalance={showBalance} />
      ) : null}
      {showHeading ? (
        <div className="mb-3">
          <h3 className="text-[18px] font-medium tracking-tight text-foreground md:text-[20px]">
            {t("My Collaterals")}
          </h3>
          <p className="mt-1 text-[13px] text-muted-foreground">{formatSectionCount(rows.length, "asset", "assets")}</p>
        </div>
      ) : null}
      {rows.length === 0 ? (
        <div className="rounded-radius-md border border-dashed border-border px-6 py-10 text-center text-[13px] text-muted-foreground">
          {t("No collateral deposited yet. Supply an asset to start backing loans.")}
        </div>
      ) : (
        <>
          <DesktopTableSurface className="!rounded-none">
            <ScrollableTable layout={SUPPLIES_LAYOUT}>
              <thead>
                <tr className={TABLE_HEADER_ROW}>
                  <th className={cn(TABLE_HEADER_CELL, "px-4", tableStickyCell("header"))}>
                    <SuppliesMetricHeader
                      label={t("Collateral")}
                      help={t("The collateral asset backing your borrowing, valued at its live price.")}
                    />
                  </th>
                  <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                    <SuppliesMetricHeader
                      label={t("Value")}
                      help={t("Live value of this collateral, and the LP trading fees it earns.")}
                    />
                  </th>
                  <th className={cn(TABLE_HEADER_CELL, "whitespace-nowrap px-4")}>
                    <SuppliesMetricHeader
                      label={t("Borrow Power")}
                      help={t(
                        "How much more you can borrow against this collateral; the % shows how much of your liquidation limit is already used.",
                      )}
                    />
                  </th>
                  <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                    <SuppliesMetricHeader
                      label={t("Risk")}
                      help={t(
                        "Health factor, and the collateral value at which this position is liquidated. Below 1.0 triggers liquidation.",
                      )}
                    />
                  </th>
                  <th className={cn(TABLE_HEADER_CELL, "px-4 pr-5 text-right")}>
                    <span className="sr-only">{t("Manage")}</span>
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border dark:divide-white/6">
                {rows.map((row) => {
                  const visuals = row.pool.visuals.map(homeVisualToBorrowVisual) as [
                    ReturnType<typeof homeVisualToBorrowVisual>,
                    ReturnType<typeof homeVisualToBorrowVisual>,
                  ]
                  const hfTone = healthFactorToneClass(row.healthFactor)
                  const detailHref = `/borrow/markets/${row.pool.id}`
                  // Per-collateral borrow-power utilization, computed the same way as the global
                  // Borrow Health card (borrowed ÷ liquidation value) and tinted with its palette.
                  const usedPct =
                    row.liquidationThresholdUsd > 0
                      ? Math.min(100, (row.borrowedUsd / row.liquidationThresholdUsd) * 100)
                      : 0
                  // Spoke/venue context distinguishes two positions on the same pair but
                  // different spokes; reuse the borrow market-context helper.
                  const spokeLabel = formatBorrowMarketContext({ venue: row.pool.venue, feeTier: "" })
                  return (
                    <tr
                      key={row.pool.id}
                      className={`${TABLE_BODY_ROW} group cursor-pointer transition-colors`}
                      onClick={() => router.push(detailHref)}
                    >
                      <td className={cn(TABLE_CELL_PADDING, "pl-6", tableStickyCell("body"))}>
                        {/* Collateral column: the LP pair over its spoke/venue, so two positions on
                            the same pair but different spokes stay distinct. */}
                        <TokenPairCell visuals={visuals} name={row.pool.name} subtitle={spokeLabel} size="md" />
                      </td>
                      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
                        <div className={TABLE_CELL_NUMERIC}>{m(compact(row.pool.collateralUsd))}</div>
                        <div className={cn(TABLE_CELL_CAPTION, "tabular-nums")}>
                          {formatApy(row.pairApr)} {t("LP APR")}
                        </div>
                      </td>
                      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
                        <div className={TABLE_CELL_NUMERIC}>{m(compact(row.remainingBorrowPowerUsd))}</div>
                        <div className={cn(TABLE_CELL_CAPTION, liqUtilizationPercentTextClass(usedPct))}>
                          {m(`${usedPct.toFixed(0)}% ${t("used")}`)}
                        </div>
                      </td>
                      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
                        <HfNumber size="table" value={m(formatHealthFactor(row.healthFactor))} tone={hfTone} />
                        {/* With no debt in scope (HF ∞) there is nothing to liquidate; the collateral's
                            liquidation value next to "∞" read like a liquidation price. */}
                        <div className={TABLE_CELL_CAPTION}>
                          {Number.isFinite(row.healthFactor) ? (
                            <>
                              {t("Liq.")} {m(exact(row.liquidationThresholdUsd))}
                            </>
                          ) : (
                            t("No debt")
                          )}
                        </div>
                      </td>
                      <td className={cn(TABLE_CELL_PADDING_TRAILING, "text-right", TABLE_ROW_HOVER_RIGHT)}>
                        {/* Desktop only — the mobile cards below keep their labelled
                            buttons. The row already opens detailHref on click, so the
                            arrow points at that rather than offering a rival control. */}
                        <button
                          type="button"
                          aria-label={t("Manage")}
                          title={t("Manage")}
                          className={ROW_OPEN_ARROW_CLASS}
                          onClick={(event) => {
                            event.stopPropagation()
                            router.push(detailHref)
                          }}
                        >
                          <RowOpenArrowIcon />
                        </button>
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

export function SuppliesHealthFactorCard({
  averageHealthFactor,
  showBalance,
  title,
  helpText,
}: {
  averageHealthFactor: number | null
  showBalance: boolean
  /** Card title; defaults to the wallet-wide "Credit Health" used on the Borrow tab. */
  title?: string
  /** Help tooltip; defaults to the wallet-wide aggregate description. */
  helpText?: string
}) {
  const { t } = useTranslation()
  const status = healthFactorStatusLabel(averageHealthFactor)
  const hfLabel = formatHealthFactor(averageHealthFactor)
  const masked = !showBalance
  const activeZoneIdx = activeHealthFactorZoneIndex(averageHealthFactor)
  const cardTitle = title ?? t("Credit Health")
  const cardHelp =
    helpText ??
    t(
      "Wallet-wide health factor: total liquidation value divided by total borrowed. 2.5 and above is comfortable; below 1.2 risks liquidation.",
    )

  return (
    <div className={`${DASHBOARD_SNAPSHOT_SURFACE_CLASS} px-5 py-4 md:px-6 md:py-5`}>
      <div className="flex h-6 items-center justify-between gap-3">
        <div className="flex items-baseline gap-2">
          <span className="font-data text-[20px] font-normal leading-none tracking-tight text-foreground">
            {masked ? "••" : hfLabel}
          </span>
          <span className="text-[13px] font-normal text-foreground">{cardTitle}</span>
          <ActionMetricHelp topic={cardTitle} text={cardHelp} />
        </div>
        <span
          className={cn(
            "inline-flex items-center gap-1.5 rounded-full bg-table-header px-2.5 py-0.5 text-[10px] font-normal tracking-wide",
            status.tone === "positive" && "text-success",
            status.tone === "warning" && "text-amber-600",
            status.tone === "danger" && "text-rose-600",
            status.tone === "default" && "text-muted-foreground",
          )}
        >
          <span
            className={cn(
              "inline-block size-1.5 rounded-full",
              status.tone === "positive" && "bg-emerald-500",
              status.tone === "warning" && "bg-amber-500",
              status.tone === "danger" && "bg-rose-500",
              status.tone === "default" && "bg-muted-foreground",
            )}
          />
          {masked ? "••" : t(status.label)}
        </span>
      </div>

      <div className="mt-9">
        <HealthFactorPositionBar value={averageHealthFactor} heightClassName="h-2.5" />

        <div className="mt-4 flex h-4 items-center justify-between text-[11px] font-medium text-muted-foreground">
          {HF_ZONES.map((zone, index) => {
            const isActive = index === activeZoneIdx
            return (
              <span key={zone.id} className={cn("inline-flex items-center gap-1.5", isActive && "text-foreground")}>
                <span className={cn("size-1.5 rounded-full", isActive ? zone.color : cn(zone.color, "opacity-40"))} />
                {t(zone.label)}
              </span>
            )
          })}
        </div>
      </div>
    </div>
  )
}
