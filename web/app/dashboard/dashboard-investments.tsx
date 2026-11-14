"use client"

import { useRouter } from "next/navigation"
import { ActionIcon } from "@/app/components/action-icon"
import { TableHeaderHint } from "@/app/components/table-header-hint"
import { Button } from "@/components/ui/button"
import { actionPagePath } from "@/app/lib/action-system/contracts"
import { DesktopTableSurface, HoverActionGroup, ScrollableTable } from "@/app/components/market-table-primitives"
import {} from "@/app/components/market-card-primitives"
import { useAmountDisplayPreferences } from "@/app/components/display-preferences"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { TokenIcon } from "@/app/components/token-icon"
import type { PortfolioLendTabData, PortfolioSupplyPosition } from "@/app/lib/data/providers/portfolio"
import { LiveInterestEarnedUsd } from "@/app/dashboard/live-accrual"
import { formatUsdExact } from "@/app/lib/borrow-sim"
import { getActiveCurrency } from "@/app/lib/currency/active-rate"
import {
  DASHBOARD_TABLE_REFERENCE_PX,
  TABLE_ACTION_BUTTON,
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
  formatTableHeaderLabel,
  tableColumnLayout,
  tableStickyCell,
} from "@/app/lib/ui/table-row-hover"
import { cn } from "@/lib/utils"
import { TokenTickerPriceLabel } from "@/app/lib/ui/token-ticker-price-label"

const MASK = "••••"

const LEND_POSITIONS_LAYOUT = tableColumnLayout(
  [
    "identityCompact",
    "metric", // Deposited
    "compact", // APY + earned
    "actionPhone2", // Withdraw (+ Add on phones)
  ],
  { referenceWidth: DASHBOARD_TABLE_REFERENCE_PX },
)

function InvestmentsMetricHeader({
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

function formatClaimableUsd(value: number) {
  const { rate, symbol, zeroDecimal } = getActiveCurrency()
  const digits = zeroDecimal ? 0 : 2
  return `${symbol}${(value * rate).toLocaleString("en-US", {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  })}`
}

function formatTokenAmount(value: number, symbol: string) {
  // Adaptive precision (matches the wallet Tokens table): more decimals for small
  // balances so `amount × unit price` reconciles with the USD line instead of losing
  // a few dollars to a hard 2-decimal round on high-unit-price tokens like weETH.
  const maximumFractionDigits = value >= 100 ? 2 : value >= 1 ? 4 : 6
  return `${value.toLocaleString("en-US", { maximumFractionDigits })} ${symbol}`
}

function resolveMarketId(token: PortfolioSupplyPosition) {
  return token.marketId ?? token.symbol.toLowerCase()
}

/**
 * Per-asset interest earned. When `anchorMs` is provided it accrues in real time at
 * this position's own rate (suppliedUsd × APY) from the supply moment — so the column
 * ticks live and the rows sum exactly to the "Interest Earned" metric on Lend Balance
 * (whose rate is totalSupplied × net-APY = Σ suppliedᵢ × apyᵢ). Falls back to the
 * static ledger value when no anchor is passed (interest excludes protocol rewards).
 */
function EarnedCell({
  token,
  anchorMs,
  show,
  className,
}: {
  token: PortfolioSupplyPosition
  anchorMs: number | null | undefined
  show: boolean
  className?: string
}) {
  if (!show) return <span className={className}>{MASK}</span>
  const baseUsd = token.interestUsd ?? token.earnedUsd
  if (anchorMs === undefined) return <span className={className}>+{formatUsdExact(baseUsd)}</span>
  return (
    <span className={className}>
      +
      <LiveInterestEarnedUsd
        anchorMs={anchorMs}
        ratePerYearUsd={(token.suppliedUsd * token.apyPct) / 100}
        baseUsd={baseUsd}
        fractionDigits={4}
      />
    </span>
  )
}

export function DashboardInvestments({
  investments,
  rewardsSummary,
  onClaimRewards,
  isClaimingRewards = false,
  showHeading = true,
  returnHref,
  title = "Assets",
  countLabel,
  accrualSinceMs,
}: {
  investments: PortfolioSupplyPosition[]
  rewardsSummary?: PortfolioLendTabData["rewardsSummary"]
  onClaimRewards?: () => void
  isClaimingRewards?: boolean
  showHeading?: boolean
  // Where the action flow's close button should land. Defaults to the market
  // detail page; the dashboard passes its own URL so closing returns you here.
  returnHref?: string
  title?: string
  countLabel?: string
  // When set, the Earned column accrues live from this supply-start anchor (see
  // EarnedCell). Omit to keep the static ledger value.
  accrualSinceMs?: number | null
}) {
  const router = useRouter()
  const { t } = useTranslation()
  const { showDollarAmounts } = useAmountDisplayPreferences()
  const claimableUsd = rewardsSummary?.claimableUsd ?? 0
  const m = (value: string) => (showDollarAmounts ? value : MASK)
  // `suppliedUsd` is already valued at the live oracle price upstream (LendAccountSection),
  // so the Deposited column, "Total Supplied" and the interest accrual all read the same
  // number — the table sums exactly to the headline.

  return (
    <section className={showHeading ? "mb-8" : undefined}>
      {showHeading ? (
        <div className="mb-3 flex items-center justify-between gap-4">
          <div>
            <h2 className="text-[18px] font-medium tracking-tight text-foreground md:text-[20px]">{title}</h2>
            {countLabel ? <p className="mt-1 text-[13px] text-muted-foreground">{countLabel}</p> : null}
          </div>
          {claimableUsd > 0 && onClaimRewards ? (
            <Button type="button" size="sm" disabled={isClaimingRewards} onClick={onClaimRewards}>
              {isClaimingRewards ? "Claiming..." : `Claim ${formatClaimableUsd(claimableUsd)}`}
            </Button>
          ) : null}
        </div>
      ) : claimableUsd > 0 && onClaimRewards ? (
        <div className="mb-3 flex justify-end">
          <Button type="button" size="sm" disabled={isClaimingRewards} onClick={onClaimRewards}>
            {isClaimingRewards ? "Claiming..." : `Claim ${formatClaimableUsd(claimableUsd)}`}
          </Button>
        </div>
      ) : null}

      {investments.length === 0 ? (
        <div className="rounded-radius-md border border-dashed border-border px-6 py-10 text-center text-[13px] text-muted-foreground">
          No lending positions yet. Supply assets to start earning yield.
        </div>
      ) : (
        <>
          <DesktopTableSurface className="!rounded-none">
            <ScrollableTable layout={LEND_POSITIONS_LAYOUT}>
              <thead>
                <tr className={TABLE_HEADER_ROW}>
                  <th className={cn(TABLE_HEADER_CELL, "px-4", tableStickyCell("header"))}>
                    <InvestmentsMetricHeader
                      label={t("Asset")}
                      help={t("The token you've supplied to earn lending yield.")}
                    />
                  </th>
                  <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                    <InvestmentsMetricHeader
                      label={t("Deposited")}
                      help={t("Your supplied balance in this asset, valued at its live price.")}
                    />
                  </th>
                  <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                    <InvestmentsMetricHeader
                      label={t("APY")}
                      help={t("Current annual percentage yield on your deposit, before protocol rewards.")}
                    />
                  </th>
                  <th className={cn(TABLE_HEADER_CELL, "px-4 pr-5 text-right")}>
                    <span className="sr-only">{t("Quick actions")}</span>
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border dark:divide-white/6">
                {investments.map((token) => {
                  const marketId = resolveMarketId(token)
                  const detailHref = `/lend/markets/${marketId}`
                  return (
                    <tr
                      key={token.id}
                      className={cn(TABLE_BODY_ROW, "group cursor-pointer transition-colors")}
                      onClick={() => router.push(detailHref)}
                    >
                      <td className={cn(TABLE_CELL_PADDING, "pl-6", tableStickyCell("body"))}>
                        <div className="flex min-w-0 items-center gap-3">
                          <TokenIcon symbol={token.symbol} size="table" />
                          <div className="flex min-w-0 flex-col">
                            <span className={cn("truncate", TABLE_CELL_PRIMARY)}>{token.name}</span>
                            <span className={cn("min-w-0 truncate tabular-nums", TABLE_CELL_SECONDARY)}>
                              <TokenTickerPriceLabel symbol={token.symbol} />
                            </span>
                          </div>
                        </div>
                      </td>
                      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
                        <div className={TABLE_CELL_NUMERIC}>{m(formatTokenAmount(token.balance, token.symbol))}</div>
                        <div className={cn(TABLE_CELL_SECONDARY, "tabular-nums")}>
                          {m(formatUsdExact(token.suppliedUsd))}
                        </div>
                      </td>
                      <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
                        <div className={TABLE_CELL_NUMERIC}>{token.apyPct.toFixed(2)}%</div>
                        <EarnedCell
                          token={token}
                          anchorMs={accrualSinceMs}
                          show={showDollarAmounts}
                          className={cn(TABLE_CELL_SECONDARY_UNCOLORED, "text-success")}
                        />
                      </td>
                      <td className={cn(TABLE_CELL_PADDING_TRAILING, "text-right", TABLE_ROW_HOVER_RIGHT)}>
                        <HoverActionGroup className="gap-2">
                          {/* Add is phone-only: desktop rows open the market, which has Deposit. */}
                          <Button
                            type="button"
                            size="table"
                            variant="table-primary"
                            className="w-auto md:hidden"
                            onClick={(event) => {
                              event.stopPropagation()
                              router.push(
                                actionPagePath("lend", "deposit", {
                                  market: marketId,
                                  return: returnHref ?? detailHref,
                                }),
                              )
                            }}
                          >
                            <ActionIcon label="Deposit" />
                            Add
                          </Button>
                          <Button
                            type="button"
                            size="table"
                            variant="table-secondary"
                            className={TABLE_ACTION_BUTTON}
                            onClick={(event) => {
                              event.stopPropagation()
                              router.push(
                                actionPagePath("lend", "withdraw", {
                                  market: marketId,
                                  return: returnHref ?? detailHref,
                                }),
                              )
                            }}
                          >
                            <ActionIcon label="Withdraw" />
                            Withdraw
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
