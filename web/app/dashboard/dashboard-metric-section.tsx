"use client"

import type { ReactNode } from "react"
import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import { LiveInterestEarnedUsd, LiveInterestOwedUsd, LiveYieldGeneratedPct } from "./live-accrual"
import { cn } from "@/lib/utils"
import { useAmountDisplayPreferences } from "@/app/components/display-preferences"
import { formatUsdExact } from "@/app/lib/borrow-sim"
import { formatHealthFactor } from "@/app/lib/data/borrow-domain"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import type { BorrowBalanceMetrics, LendBalanceMetrics, MultiplyBalanceMetrics } from "./dashboard-tab-metrics"
import { formatPercent } from "@/app/lib/format"

const MASK = "••••"

function formatLeverage(value: number) {
  if (!Number.isFinite(value) || value <= 0) return "—"
  // "x" like every other leverage figure ("2.00x leverage", "Max 5.00x").
  return `${value.toFixed(2)}x`
}

type MetricItem = {
  label: string
  value: ReactNode
  description: string
  /** Colors the value emerald ("up") or rose ("down") — e.g. interest earned vs owed. */
  tone?: "up" | "down"
}

function MetricGrid({ metrics, labelOnTop = false }: { metrics: MetricItem[]; labelOnTop?: boolean }) {
  return (
    <div className="grid w-full grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4 lg:gap-x-8">
      {metrics.map((metric) => {
        const toneClass =
          metric.tone === "up"
            ? "text-emerald-700 dark:text-emerald-400"
            : metric.tone === "down"
              ? "text-rose-700 dark:text-rose-400"
              : "text-foreground"
        const value = (
          <div
            className={cn(
              "font-data text-[clamp(1.35rem,1.8vw,1.95rem)] font-medium leading-none tracking-normal tabular-nums",
              toneClass,
            )}
          >
            {metric.value}
          </div>
        )
        const label = (
          <div className="flex items-center gap-1.5">
            <span className="text-[13px] text-muted-foreground">{metric.label}</span>
            <ActionMetricHelp text={metric.description} topic={metric.label} />
          </div>
        )
        return (
          <article
            key={metric.label}
            className="flex min-w-0 items-baseline justify-between gap-3 sm:block sm:space-y-1.5"
          >
            {labelOnTop ? (
              <>
                {label}
                {value}
              </>
            ) : (
              <>
                {value}
                {label}
              </>
            )}
          </article>
        )
      })}
    </div>
  )
}

/** Wallet-level Borrow Balance, aggregated across every Borrow position on the wallet. */
export function DashboardCreditOverviewSection({
  title,
  metrics,
  hideHeading = false,
}: {
  title: string
  metrics: BorrowBalanceMetrics
  hideHeading?: boolean
}) {
  const { showDollarAmounts } = useAmountDisplayPreferences()
  const { t } = useTranslation()
  const m = (value: string) => (showDollarAmounts ? value : MASK)
  const hfLabel = formatHealthFactor(metrics.healthFactor)

  const items: MetricItem[] = [
    {
      label: t("Net Value"),
      value: m(formatUsdExact(metrics.netValueUsd)),
      description: t("Your collateral value minus what you owe — the equity this tab adds to your portfolio"),
    },
    {
      label: t("Collateral Value"),
      value: m(formatUsdExact(metrics.collateralValueUsd)),
      description: t("LP positions currently securing your loans"),
    },
    {
      label: t("Total Borrowed"),
      value: m(formatUsdExact(metrics.totalBorrowedUsd)),
      description: t("Current outstanding loan balance"),
    },
    {
      label: t("Available to Borrow"),
      value: m(formatUsdExact(metrics.availableToBorrowUsd)),
      description: t("Additional amount you can borrow against your pledged collateral within Avana credit limits"),
    },
    {
      label: t("Health Factor"),
      value: showDollarAmounts ? hfLabel : MASK,
      description: t(
        "Wallet-wide liquidation value divided by total borrowed. Higher is safer; below 1 risks liquidation.",
      ),
    },
    {
      label: t("Liquidation Buffer"),
      value: showDollarAmounts
        ? metrics.liquidationBufferUsd === null
          ? "—"
          : formatUsdExact(metrics.liquidationBufferUsd)
        : MASK,
      description: t("Amount an active loan can lose before reaching liquidation; unavailable when you have no debt"),
    },
    {
      label: t("Net APY"),
      value: showDollarAmounts ? formatPercent(metrics.netApyPct) : MASK,
      description: t("Weighted average APY across all active positions"),
    },
    {
      label: t("Interest Owed"),
      tone: "down",
      value: !showDollarAmounts ? (
        MASK
      ) : metrics.accrualSinceMs != null && metrics.interestOwedPerYearUsd != null ? (
        <LiveInterestOwedUsd
          anchorMs={metrics.accrualSinceMs}
          ratePerYearUsd={metrics.interestOwedPerYearUsd}
          baseUsd={metrics.interestOwedUsd}
        />
      ) : (
        formatUsdExact(metrics.interestOwedUsd)
      ),
      description: t("Total interest accrued on your outstanding loans"),
    },
  ]

  return (
    <section className="space-y-4 pb-3">
      {hideHeading ? null : (
        <h2 className="text-[20px] font-medium tracking-[-0.01em] text-foreground md:text-[20px]">{title}</h2>
      )}
      <MetricGrid labelOnTop metrics={items} />
    </section>
  )
}

/** Wallet-level Multiply Balance, aggregated across every Multiply position on the wallet. */
export function DashboardMultiplyBalanceSection({
  title,
  metrics,
  hideHeading = false,
}: {
  title: string
  metrics: MultiplyBalanceMetrics
  hideHeading?: boolean
}) {
  const { showDollarAmounts } = useAmountDisplayPreferences()
  const { t } = useTranslation()
  const m = (value: string) => (showDollarAmounts ? value : MASK)
  const hfLabel = formatHealthFactor(metrics.healthFactor)

  const items: MetricItem[] = [
    {
      label: t("Net Value"),
      value: m(formatUsdExact(metrics.netValueUsd)),
      description: t("Total value of your positions minus outstanding loans"),
    },
    {
      label: t("Gross Exposure"),
      value: m(formatUsdExact(metrics.positionValueUsd)),
      description: t("Gross Multiply exposure after looping across all positions"),
    },
    {
      label: t("Total Borrowed"),
      value: m(formatUsdExact(metrics.totalBorrowedUsd)),
      description: t("Current outstanding loan balance"),
    },
    {
      label: t("Leverage"),
      value: showDollarAmounts ? formatLeverage(metrics.leverageX) : MASK,
      description: t("Portfolio leverage as position value divided by equity"),
    },
    {
      label: t("Health Factor"),
      value: showDollarAmounts ? hfLabel : MASK,
      description: t(
        "Combined liquidation value divided by total Multiply debt. Higher is safer; below 1 risks liquidation.",
      ),
    },
    {
      label: t("Liquidation Buffer"),
      value: m(formatUsdExact(metrics.liquidationBufferUsd)),
      description: t("Distance from liquidation based on current collateral value"),
    },
    {
      label: t("Net APY"),
      value: showDollarAmounts ? formatPercent(metrics.netApyPct) : MASK,
      description: t("Equity-weighted net APY after supply yield and borrow cost"),
    },
    {
      label: t("Interest Earned"),
      tone: metrics.interestEarnedUsd < 0 ? "down" : "up",
      value: showDollarAmounts ? (
        <LiveInterestEarnedUsd
          anchorMs={metrics.accrualSinceMs}
          ratePerYearUsd={metrics.interestPerYearUsd}
          baseUsd={metrics.interestEarnedUsd}
          fractionDigits={2}
        />
      ) : (
        MASK
      ),
      description: t(
        "Net carry earned across your Multiply loops, accruing in real time (supply yield minus borrow cost)",
      ),
    },
  ]

  return (
    <section className="space-y-4 pb-3">
      {hideHeading ? null : (
        <h2 className="text-[20px] font-medium tracking-[-0.01em] text-foreground md:text-[20px]">{title}</h2>
      )}
      <MetricGrid labelOnTop metrics={items} />
    </section>
  )
}

/**
 * Wallet-level Lend Balance across every active Lend position. Rewards stay on the
 * Claim path / assets table, not these cards.
 */
export function DashboardLendPerformanceSection({
  title,
  metrics,
  hideHeading = false,
}: {
  title: string
  metrics: LendBalanceMetrics
  hideHeading?: boolean
}) {
  const { showDollarAmounts } = useAmountDisplayPreferences()
  const { t } = useTranslation()
  const m = (value: string) => (showDollarAmounts ? value : MASK)

  const projectionHint = t("Projected earnings at current rates")
  // Yearly USD at the current blend; the live counters accrue it from `accrualSinceMs`.
  const accrualRatePerYearUsd = metrics.totalSuppliedUsd * (metrics.netApyPct / 100)

  const items: MetricItem[] = [
    {
      label: t("Total Supplied"),
      value: m(formatUsdExact(metrics.totalSuppliedUsd)),
      description: t("Total assets currently supplied and earning yield"),
    },
    {
      label: t("Net APY"),
      value: showDollarAmounts ? formatPercent(metrics.netApyPct) : MASK,
      description: t("Weighted average APY across all supplied positions"),
    },
    {
      label: t("Interest Earned"),
      tone: "up",
      value: showDollarAmounts ? (
        <LiveInterestEarnedUsd
          anchorMs={metrics.accrualSinceMs}
          ratePerYearUsd={accrualRatePerYearUsd}
          baseUsd={metrics.interestEarnedUsd}
          fractionDigits={2}
        />
      ) : (
        MASK
      ),
      description: t("Supply interest accruing in real time across your lending positions (excludes protocol rewards)"),
    },
    {
      label: t("Yield Generated"),
      value: showDollarAmounts ? (
        <LiveYieldGeneratedPct
          anchorMs={metrics.accrualSinceMs}
          ratePerYearUsd={accrualRatePerYearUsd}
          principalUsd={metrics.totalSuppliedUsd}
          baseUsd={metrics.interestEarnedUsd}
        />
      ) : (
        MASK
      ),
      description: t("Interest earned as a percentage of principal you supplied"),
    },
    {
      label: t("1 Day"),
      value: showDollarAmounts ? `+${formatUsdExact(metrics.projectedEarnings1dUsd)}` : MASK,
      description: projectionHint,
    },
    {
      label: t("30 Days"),
      value: showDollarAmounts ? `+${formatUsdExact(metrics.projectedEarnings30dUsd)}` : MASK,
      description: projectionHint,
    },
    {
      label: t("90 Days"),
      value: showDollarAmounts ? `+${formatUsdExact(metrics.projectedEarnings90dUsd)}` : MASK,
      description: projectionHint,
    },
    {
      label: t("6 Months"),
      value: showDollarAmounts ? `+${formatUsdExact(metrics.projectedEarnings6mUsd)}` : MASK,
      description: projectionHint,
    },
  ]

  return (
    <section className="space-y-4 pb-3">
      {hideHeading ? null : (
        <h2 className="text-[20px] font-medium tracking-[-0.01em] text-foreground md:text-[20px]">{title}</h2>
      )}
      <MetricGrid labelOnTop metrics={items} />
    </section>
  )
}
