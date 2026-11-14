"use client"

import dynamic from "next/dynamic"
import { useCallback, useMemo, useState, type ReactNode } from "react"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { resolveAvailableRanges, resolveSeriesChange, resolveSeriesTone } from "./chart-data"
import { ChartRangeSelector } from "./chart-range-selector"
import { formatChartAxis, formatChartValue } from "./format"
import { HeroBalanceDisplay } from "./hero-balance-display"
import type { HeroScrubSample } from "./hero-scrub"
import type { ChartFeed, ChartRangeOption, ChartValueFormat } from "./types"

/** Masked axis characters shown when the privacy toggle hides amounts. */
export const HERO_AXIS_MASK = "••"

/**
 * Y-axis label formatter. When the privacy toggle hides amounts (`hideValue`), the
 * axis is masked too — otherwise the chart still leaks the portfolio magnitude via
 * its "$40.7K" gridline labels while the headline reads "••••".
 */
export function heroAxisFormatter(valueFormat: ChartValueFormat, hideValue: boolean): (value: number) => string {
  if (hideValue) return () => HERO_AXIS_MASK
  return (value: number) => formatChartAxis(valueFormat, value)
}

const HeroAreaChart = dynamic(() => import("./hero-area-chart").then((mod) => mod.HeroAreaChart), {
  ssr: false,
  loading: () => <HeroAreaChartPlaceholder />,
})

function HeroAreaChartPlaceholder() {
  return (
    <div
      aria-hidden
      className="relative h-[210px] before:pointer-events-none before:absolute before:inset-0 before:bg-[radial-gradient(circle_at_1px_1px,rgba(0,0,0,0.12)_1px,transparent_0)] before:[background-size:18px_18px] before:[mask-image:radial-gradient(ellipse_at_center,black_58%,transparent_100%)] before:content-[''] dark:before:bg-[radial-gradient(circle_at_1px_1px,rgba(255,255,255,0.12)_1px,transparent_0)] sm:h-[240px]"
    />
  )
}

type MarketHeroChartProps = {
  feed: ChartFeed
  defaultRange?: ChartRangeOption
  /** Hide the headline value (used for privacy toggles on the portfolio). */
  hideValue?: boolean
  height?: number
  gradientId?: string
  /** Small uppercase label naming the metric (e.g. "Total borrows"). */
  label?: string
  showMeta?: boolean
  metricTabs?: readonly string[]
  activeMetricTab?: string
  onMetricTabChange?: (tab: string) => void
  chartTone?: "positive" | "negative" | "neutral"
  balanceVariant?: "default" | "strong" | "quiet"
  balanceClassName?: string
  /** Inline node next to the headline value (e.g. an info tooltip). */
  balanceSuffix?: ReactNode
  /** Node under the headline delta (e.g. an "Assets · Debt" breakdown). */
  balanceSubtitle?: ReactNode
  /** When false, lock to `defaultRange` and hide the 1D/1W/… pills. */
  showRangeSelector?: boolean
  /**
   * Drop the intraday "1D" range from the selector. Daily-granularity (live/Convex-backed)
   * feeds synthesize 1D as a seeded random walk, so offering it lets the headline jump to
   * values that never happened. Longer ranges still slice real history.
   */
  hideIntradayRange?: boolean
}

/**
 * The universal hero chart used across portfolio, pool, and asset pages.
 * Give it a `ChartFeed` (from `app/lib/chart-feeds`) and it renders the
 * balance, the area chart, and the range selector — with hover-to-inspect.
 */
export function MarketHeroChart({
  feed,
  defaultRange = "1D",
  hideValue = false,
  height,
  gradientId = "marketHeroFill",
  label,
  showMeta = true,
  metricTabs,
  activeMetricTab,
  onMetricTabChange,
  chartTone,
  balanceVariant = "default",
  balanceClassName,
  balanceSuffix,
  balanceSubtitle,
  showRangeSelector = true,
  hideIntradayRange = false,
}: MarketHeroChartProps) {
  // Only offer ranges the feed can actually populate. Daily-granularity feeds omit
  // 1H/1D (which would render as duplicate sparse 2-point lines). Live heroes also opt
  // out of the synthetic 1D via `hideIntradayRange` so the headline can't jump to it.
  const availableRanges = useMemo(() => {
    const resolved = resolveAvailableRanges(feed.rangeData)
    if (!hideIntradayRange) return resolved
    const withoutIntraday = resolved.filter((range) => range !== "1D")
    return withoutIntraday.length > 0 ? withoutIntraday : resolved
  }, [feed.rangeData, hideIntradayRange])
  const [requestedRange, setRequestedRange] = useState<ChartRangeOption>(defaultRange)
  const activeRange = showRangeSelector
    ? availableRanges.includes(requestedRange)
      ? requestedRange
      : availableRanges[0]
    : defaultRange
  const [scrub, setScrub] = useState<HeroScrubSample | null>(null)
  // Subscribe so headline / delta / axis re-render when the active currency changes.
  useCurrency()

  const points = feed.rangeData[activeRange]
  const tipValue = points[points.length - 1]?.value ?? 0

  // The chart color and the headline delta both follow the active range's
  // real trend (first → last), so a dip shows red everywhere.
  const rangeTone = resolveSeriesTone(points)
  const rangeChange = useMemo(() => resolveSeriesChange(points), [points])

  const displayValue = scrub?.value ?? tipValue
  const firstValue = points[0]?.value ?? displayValue
  const scrubPct = firstValue ? ((displayValue - firstValue) / firstValue) * 100 : 0
  const tone = scrub ? (scrubPct >= 0 ? ("positive" as const) : ("negative" as const)) : rangeTone

  const formatValue = useCallback((v: number) => formatChartValue(feed.valueFormat, v), [feed.valueFormat])
  const formatDeltaAbs = useCallback((v: number) => formatChartValue(feed.valueFormat, Math.abs(v)), [feed.valueFormat])
  const formatDeltaPct = useCallback((v: number) => `${Math.abs(v).toFixed(2)}%`, [])

  const valueText = formatValue(displayValue)

  const deltaAbs = scrub ? displayValue - firstValue : rangeChange.changeAbs
  const deltaPct = scrub ? scrubPct : rangeChange.pct
  const deltaText = `${formatDeltaAbs(deltaAbs)} (${formatDeltaPct(deltaPct)})`

  // While scrubbing, always surface the sample timestamp (Uniswap header-as-tooltip).
  // At rest, respect `showMeta` for the feed's headline meta.
  const meta = scrub ? scrub.label || undefined : showMeta ? feed.headlineMeta : undefined

  const showFooter = showRangeSelector || Boolean(metricTabs?.length)

  return (
    <div className="relative space-y-2">
      {/* Metric name kept for screen readers / internal recognition; hidden visually. */}
      {label ? (
        <p className="text-[12px] font-medium uppercase tracking-[0.08em] text-muted-foreground">{label}</p>
      ) : null}
      <HeroBalanceDisplay
        value={hideValue ? "••••••••" : valueText}
        delta={deltaText}
        deltaTone={tone}
        meta={meta}
        hidden={hideValue}
        variant={balanceVariant}
        className={balanceClassName}
        valueSuffix={balanceSuffix}
        subtitle={balanceSubtitle}
        numericValue={hideValue ? undefined : displayValue}
        formatValue={hideValue ? undefined : formatValue}
        numericDeltaAbs={hideValue ? undefined : Math.abs(deltaAbs)}
        formatDeltaAbs={hideValue ? undefined : formatDeltaAbs}
        numericDeltaPct={hideValue ? undefined : Math.abs(deltaPct)}
        formatDeltaPct={hideValue ? undefined : formatDeltaPct}
      />
      {/* A custom height is reserved here so the 210/240px loading placeholder doesn't make the
          page jump when the chart chunk arrives (detail heroes render at 310px). */}
      <div data-hero-chart-slot style={height ? { minHeight: height } : undefined}>
        <HeroAreaChart
          data={points}
          activeRange={activeRange}
          height={height}
          gradientId={gradientId}
          tone={chartTone ?? (scrub ? tone : rangeTone)}
          formatValue={formatValue}
          formatYAxis={heroAxisFormatter(feed.valueFormat, hideValue)}
          onScrubChange={setScrub}
        />
      </div>
      {showFooter ? (
        <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
          {showRangeSelector ? (
            <ChartRangeSelector activeRange={activeRange} onRangeChange={setRequestedRange} ranges={availableRanges} />
          ) : (
            <span />
          )}
          {metricTabs?.length ? (
            <ChartMetricSelector
              tabs={metricTabs}
              activeTab={activeMetricTab ?? metricTabs[0]}
              onTabChange={onMetricTabChange}
            />
          ) : null}
        </div>
      ) : null}
    </div>
  )
}

function ChartMetricSelector({
  tabs,
  activeTab,
  onTabChange,
}: {
  tabs: readonly string[]
  activeTab: string
  onTabChange?: (tab: string) => void
}) {
  return (
    <div className="inline-flex w-fit items-center gap-0.5 rounded-full border border-border bg-background p-0.5">
      {tabs.map((tab) => {
        const active = tab === activeTab
        return (
          <button
            key={tab}
            type="button"
            onClick={() => onTabChange?.(tab)}
            className={[
              "flex h-6 min-w-[52px] items-center justify-center rounded-full px-2 text-[10px] font-semibold transition-colors sm:text-[10.5px]",
              active ? "bg-muted text-foreground" : "text-foreground/75 hover:text-foreground",
            ].join(" ")}
          >
            {tab}
          </button>
        )
      })}
    </div>
  )
}
