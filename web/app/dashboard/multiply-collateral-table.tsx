"use client"

import { formatTokenDisplaySymbol } from "@/app/lib/token-icons"
import { useRouter } from "next/navigation"
import { TableHeaderHint } from "@/app/components/table-header-hint"
import { useAmountDisplayPreferences } from "@/app/components/display-preferences"
import {
  DesktopTableSurface,
  ROW_OPEN_ARROW_CLASS,
  RowOpenArrowIcon,
  ScrollableTable,
} from "@/app/components/market-table-primitives"
import { TokenIcon } from "@/app/components/token-icon"
import { pairedLoopBorrowPx, TOKEN_ICON_TABLE_PAIR_WIDTH_PX, TOKEN_ICON_TABLE_PX } from "@/app/lib/token-icon-sizes"
import { formatCompactUsd, formatUsdExact } from "@/app/lib/borrow-sim"
import type { MultiplyPositionLiveApy } from "@/app/dashboard/dashboard-tab-metrics"
import { LiveInterestEarnedUsd } from "@/app/dashboard/live-accrual"
import type { PortfolioMultiplyCollateral } from "@/app/lib/data/providers/portfolio"
import { healthFactorBand } from "@/app/lib/health/health-factor-bands"
import { formatHealthFactor } from "@/app/lib/home-sim"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { formatSectionCount } from "@/app/lib/ui/section-count"
import {
  DASHBOARD_TABLE_REFERENCE_PX,
  TABLE_BODY_ROW,
  TABLE_CELL_NUMERIC,
  TABLE_CELL_PADDING,
  TABLE_CELL_PADDING_TRAILING,
  TABLE_CELL_PRIMARY,
  TABLE_CELL_SECONDARY,
  TABLE_CELL_SECONDARY_UNCOLORED,
  TABLE_HEADER_CELL,
  TABLE_HEADER_ROW,
  TABLE_ROW_HOVER_BG,
  TABLE_ROW_HOVER_RIGHT,
  tableColumnLayout,
  tableStickyCell,
} from "@/app/lib/ui/table-row-hover"

const MULTIPLY_POSITIONS_LAYOUT = tableColumnLayout(
  [
    "identityCompact", // Loop
    "metric", // Value + exposure
    "compact", // Net APY + earned
    "metric", // HF + liquidation price
    "arrow",
  ],
  { referenceWidth: DASHBOARD_TABLE_REFERENCE_PX },
)
import { cn } from "@/lib/utils"

const MASK = "••••"

type NetApyByMarket = Map<string, MultiplyPositionLiveApy>

function positionEquityUsd(row: PortfolioMultiplyCollateral) {
  return Math.max(0, row.collateralUsd - row.debtUsd)
}

function formatNetApyPct(pct: number) {
  return `${pct >= 0 ? "+" : ""}${pct.toFixed(2)}%`
}

function netApyToneClass(pct: number) {
  return pct < 0 ? "text-danger" : "text-success"
}

export function MultiplyCollateralTable({
  rows,
  netApyByMarket,
  returnHref: _returnHref,
  showHeading = true,
}: {
  rows: PortfolioMultiplyCollateral[]
  netApyByMarket?: NetApyByMarket
  returnHref?: string
  showHeading?: boolean
}) {
  const router = useRouter()
  const { showDollarAmounts } = useAmountDisplayPreferences()
  const { t } = useTranslation()
  const usd = (value: number) => (showDollarAmounts ? formatCompactUsd(value) : MASK)
  const liqPrice = (value: number | null) => (value == null ? "—" : showDollarAmounts ? formatUsdExact(value) : MASK)
  const activeRows = rows.filter((row) => row.status === "open" && row.collateralUsd > 0)
  const apyFor = (row: PortfolioMultiplyCollateral) => netApyByMarket?.get(row.marketId)

  const openPosition = (row: PortfolioMultiplyCollateral) => router.push(`/multiply/markets/${row.marketId}`)
  const openManage = (event: React.MouseEvent, row: PortfolioMultiplyCollateral) => {
    event.stopPropagation()
    openPosition(row)
  }

  if (activeRows.length === 0) {
    return (
      <section>
        {showHeading ? (
          <h3 className="mb-4 text-[18px] font-medium tracking-tight text-foreground md:text-[20px]">
            {t("My Loops")}
          </h3>
        ) : null}
        <div className="rounded-radius-md border border-dashed border-border px-6 py-10 text-center text-[13px] text-muted-foreground">
          {t("No active Multiply positions")}
        </div>
      </section>
    )
  }

  return (
    <section>
      {showHeading ? (
        <div className="mb-4">
          <h3 className="text-[18px] font-medium tracking-tight text-foreground md:text-[20px]">{t("My Loops")}</h3>
          <p className="mt-1 text-[13px] text-muted-foreground">
            {formatSectionCount(activeRows.length, "loop", "loops")}
          </p>
        </div>
      ) : null}

      <DesktopTableSurface className="!rounded-none">
        <ScrollableTable layout={MULTIPLY_POSITIONS_LAYOUT}>
          <thead>
            <tr className={TABLE_HEADER_ROW}>
              <th className={cn(TABLE_HEADER_CELL, "px-4", tableStickyCell("header"))}>
                <MetricHeader
                  label={t("Loop")}
                  help={t("The collateral you supply and the asset you borrow against it to build leverage.")}
                />
              </th>
              <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                <MetricHeader
                  label={t("Value")}
                  help={t(
                    "Your own capital in the loop (exposure minus debt). Exposure is your total leveraged position.",
                  )}
                />
              </th>
              <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                <MetricHeader
                  label={t("APY")}
                  help={t(
                    "Net yield after borrow costs, on your capital. The figure below is interest earned so far, ticking live.",
                  )}
                />
              </th>
              <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                <MetricHeader
                  label={t("Risk")}
                  help={t(
                    "Health factor, and the collateral price at which this loop is liquidated. Below 1.0 triggers liquidation.",
                  )}
                />
              </th>
              <th className={cn(TABLE_HEADER_CELL, "px-4 pr-5 text-right")}>
                <span className="sr-only">{t("Manage")}</span>
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border dark:divide-white/6">
            {activeRows.map((row) => (
              <tr
                key={row.id}
                className={`${TABLE_BODY_ROW} group cursor-pointer transition-colors`}
                onClick={() => openPosition(row)}
              >
                <LoopCell row={row} />
                <ValueCell row={row} usd={usd} />
                <NetApyCell apy={apyFor(row)} showDollarAmounts={showDollarAmounts} />
                <RiskCell row={row} liqPrice={liqPrice} />
                <td className={cn(TABLE_CELL_PADDING_TRAILING, "text-right", TABLE_ROW_HOVER_RIGHT)}>
                  {/* Row-open arrow: it opens the same /multiply/markets/{id} detail page as the
                   * row click (labeled pills are reserved for actions that start a transaction). */}
                  <button
                    type="button"
                    aria-label={t("Manage")}
                    title={t("Manage")}
                    className={ROW_OPEN_ARROW_CLASS}
                    onClick={(event) => openManage(event, row)}
                  >
                    <RowOpenArrowIcon />
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </ScrollableTable>
      </DesktopTableSurface>
    </section>
  )
}

function MetricHeader({ label, help, align = "left" }: { label: string; help: string; align?: "left" | "right" }) {
  return (
    <TableHeaderHint hint={help} className={cn("inline-flex items-center gap-1", align === "right" && "justify-end")}>
      {label}
    </TableHeaderHint>
  )
}

function PairedTokenIcons({ row }: { row: PortfolioMultiplyCollateral }) {
  const borrowPx = pairedLoopBorrowPx(TOKEN_ICON_TABLE_PX)

  return (
    <span
      className="relative block shrink-0"
      style={{ height: TOKEN_ICON_TABLE_PX, width: TOKEN_ICON_TABLE_PAIR_WIDTH_PX }}
    >
      <TokenIcon symbol={row.collateralToken} size="table" className="absolute left-0 top-0" />
      <TokenIcon
        symbol={row.borrowableToken}
        size="md"
        pixelSize={borrowPx}
        className="absolute bottom-0 right-0 z-10"
      />
    </span>
  )
}

function LoopCell({ row }: { row: PortfolioMultiplyCollateral }) {
  const { t } = useTranslation()
  return (
    <td className={cn(TABLE_CELL_PADDING, "pl-6", tableStickyCell("body"))}>
      <div className="flex min-w-0 items-center gap-3">
        <PairedTokenIcons row={row} />
        <span className="min-w-0">
          <span className={cn("block truncate", TABLE_CELL_PRIMARY)}>
            {formatTokenDisplaySymbol(row.collateralToken)} / {formatTokenDisplaySymbol(row.borrowableToken)}
          </span>
          <span className={cn("block truncate", TABLE_CELL_SECONDARY)}>
            {row.multiplier.toFixed(2)}x {t("leverage")}
          </span>
        </span>
      </div>
    </td>
  )
}

function ValueCell({ row, usd }: { row: PortfolioMultiplyCollateral; usd: (value: number) => string }) {
  const { t } = useTranslation()
  return (
    <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
      <span className={cn("block", TABLE_CELL_NUMERIC)}>{usd(positionEquityUsd(row))}</span>
      <span className={cn("block", TABLE_CELL_SECONDARY)}>
        {usd(row.collateralUsd)} {t("Exp.")}
      </span>
    </td>
  )
}

function NetApyCell({
  apy,
  showDollarAmounts,
}: {
  apy: MultiplyPositionLiveApy | undefined
  showDollarAmounts: boolean
}) {
  if (!apy) {
    return (
      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
        <span className={cn("block", TABLE_CELL_NUMERIC)}>—</span>
      </td>
    )
  }
  return (
    <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
      <span className={cn("block", TABLE_CELL_NUMERIC, netApyToneClass(apy.netApyPct))}>
        {formatNetApyPct(apy.netApyPct)}
      </span>
      <span className={cn("block", TABLE_CELL_SECONDARY_UNCOLORED, "text-success")}>
        {showDollarAmounts ? (
          <LiveInterestEarnedUsd
            anchorMs={apy.accrualSinceMs}
            ratePerYearUsd={apy.ratePerYearUsd}
            baseUsd={apy.baseUsd}
          />
        ) : (
          MASK
        )}
      </span>
    </td>
  )
}

function liqPriceLabel(
  t: (key: string) => string,
  row: PortfolioMultiplyCollateral,
  liqPrice: (value: number | null) => string,
) {
  if (row.liquidationPriceUsd == null) return `${t("Liq.")} —`
  return `${t("Liq.")} ${liqPrice(row.liquidationPriceUsd)} (${formatTokenDisplaySymbol(row.collateralToken)})`
}

function RiskCell({ row, liqPrice }: { row: PortfolioMultiplyCollateral; liqPrice: (value: number | null) => string }) {
  const { t } = useTranslation()
  return (
    <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
      <span className={cn("block", TABLE_CELL_NUMERIC, healthFactorBand(row.healthFactor).textClass)}>
        {t("HF")} {formatHealthFactor(row.healthFactor)}
      </span>
      <span className={cn("block", TABLE_CELL_SECONDARY)}>{liqPriceLabel(t, row, liqPrice)}</span>
    </td>
  )
}
