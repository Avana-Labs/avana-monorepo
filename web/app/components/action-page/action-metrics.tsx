"use client"

import type { ComponentPropsWithoutRef, ReactNode } from "react"
import { Heart } from "@/app/components/icons"
import { cn } from "@/lib/utils"
import { ActionHealthFactorBar } from "@/app/components/action-page/action-health-factor-bar"
import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import { ActionTokenIcon } from "@/app/components/action-page/action-token-icon"
import { AnimatedTextValue } from "@/app/components/action-page/action-live-value"
import { LiveInterestEarnedUsd } from "@/app/dashboard/live-accrual"
import type { ActionMetricRow, ActionMetricTone } from "@/app/lib/action-system/contracts"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { ACTION_INFO_TOOLTIPS, resolveMetricTooltip } from "@/app/lib/action-system/metric-tooltips"
import {
  isHealthFactorMetric,
  parseHealthFactorValue,
  resolveMetricTone,
} from "@/app/lib/action-system/health-factor-ui"

export function ActionCard({
  children,
  className,
  ...props
}: {
  children: ReactNode
  className?: string
} & ComponentPropsWithoutRef<"div">) {
  return (
    <div
      // Flat surface, matching the Umbrella detail stats (SurfaceMetricRow) these blocks sit
      // beside. `shadow-elev-1` stacked a drop shadow under every secondary metric block on
      // the action pages and sidebars, which read as heavy next to Umbrella's shadowless rows.
      // Structure comes from the border + card background, not elevation.
      className={cn("rounded-radius-lg border border-border bg-card text-card-foreground", className)}
      {...props}
    >
      {children}
    </div>
  )
}

export function ActionInfoRow({
  label,
  value,
  tooltip,
  className,
}: {
  label: string
  value: ReactNode
  tooltip?: string
  className?: string
}) {
  const { t } = useTranslation()
  const tip = tooltip ? (ACTION_INFO_TOOLTIPS[tooltip] ?? tooltip) : undefined
  return (
    <div
      className={cn(
        "flex items-center justify-between gap-4 px-4 py-3.5 text-[15px] max-[360px]:flex-col max-[360px]:items-start max-[360px]:gap-1.5",
        className,
      )}
    >
      <div className="flex items-center gap-1.5 text-[14px] text-muted-foreground">
        <span>{t(label)}</span>
        {tip ? <ActionMetricHelp text={tip} topic={label} /> : null}
      </div>
      <div className="font-medium tabular-nums text-foreground max-[360px]:w-full">
        {typeof value === "string" || typeof value === "number" ? (
          <AnimatedTextValue text={String(value)} animateOnMount={false} />
        ) : (
          value
        )}
      </div>
    </div>
  )
}

function toneClassName(tone: ActionMetricTone) {
  return cn(
    tone === "default" && "text-foreground",
    tone === "positive" && "text-emerald-500",
    tone === "warning" && "text-amber-500",
    tone === "danger" && "text-rose-500",
  )
}

function TokenSymbolRow({ symbols }: { symbols: string[] }) {
  return (
    <div className="flex items-center gap-1.5" data-testid="borrowable-asset-icons">
      {symbols.map((symbol) => (
        <ActionTokenIcon key={symbol} symbol={symbol} />
      ))}
    </div>
  )
}

function MetricValue({
  label,
  value,
  before,
  after,
  tone = "default",
  id,
  tokenSymbols,
  liveUsd,
}: {
  label: string
  value: string
  before?: string
  after?: string
  tone?: ActionMetricTone
  id?: string
  tokenSymbols?: string[]
  liveUsd?: ActionMetricRow["liveUsd"]
}) {
  if (tokenSymbols && tokenSymbols.length > 0) {
    return <TokenSymbolRow symbols={tokenSymbols} />
  }

  const resolvedTone = resolveMetricTone(label, tone, after, id)
  const showHeart = isHealthFactorMetric(label, id)

  if (before && after) {
    return (
      <div className={cn("inline-flex items-center gap-1.5 font-medium tabular-nums", toneClassName(resolvedTone))}>
        <span className="text-muted-foreground">
          {liveUsd ? (
            <LiveInterestEarnedUsd
              anchorMs={liveUsd.anchorMs}
              ratePerYearUsd={liveUsd.before.ratePerYearUsd}
              baseUsd={liveUsd.before.baseUsd}
              fractionDigits={liveUsd.fractionDigits}
            />
          ) : (
            before
          )}
        </span>
        <span className="text-muted-foreground/70">→</span>
        <span className={cn("inline-flex items-center gap-1", toneClassName(resolvedTone))}>
          {showHeart ? (
            <Heart className={cn("size-3.5", resolvedTone === "positive" && "fill-emerald-500")} aria-hidden />
          ) : null}
          {liveUsd ? (
            <LiveInterestEarnedUsd
              anchorMs={liveUsd.anchorMs}
              ratePerYearUsd={liveUsd.after.ratePerYearUsd}
              baseUsd={liveUsd.after.baseUsd}
              fractionDigits={liveUsd.fractionDigits}
            />
          ) : (
            <AnimatedTextValue text={after} animateOnMount />
          )}
        </span>
      </div>
    )
  }

  return (
    <div className={cn("inline-flex items-center gap-1 font-medium tabular-nums", toneClassName(resolvedTone))}>
      {showHeart ? (
        <Heart className={cn("size-3.5", resolvedTone === "positive" && "fill-emerald-500")} aria-hidden />
      ) : null}
      <AnimatedTextValue text={value} animateOnMount />
    </div>
  )
}

export function ActionMetricRow({
  label,
  value,
  before,
  after,
  tone = "default",
  tooltip,
  id,
  tokenSymbols,
  liveUsd,
}: ActionMetricRow) {
  const { t } = useTranslation()
  const tip = resolveMetricTooltip(id, label, tooltip)
  return (
    <div data-testid={`metric-${label.toLowerCase().replace(/\s+/g, "-")}`}>
      <div className="flex items-center justify-between gap-4 px-4 py-3.5 text-[15px] max-[360px]:flex-col max-[360px]:items-start max-[360px]:gap-1.5">
        <div className="flex items-center gap-1.5 text-[14px] text-muted-foreground">
          <span>{t(label)}</span>
          {tip ? <ActionMetricHelp text={tip} topic={label} /> : null}
        </div>
        <div className="max-[360px]:w-full">
          <MetricValue
            label={label}
            value={value}
            before={before}
            after={after}
            tone={tone}
            id={id}
            tokenSymbols={tokenSymbols}
            liveUsd={liveUsd}
          />
        </div>
      </div>
    </div>
  )
}

export function ActionMetricsBlock({ rows }: { rows: ActionMetricRow[] }) {
  if (rows.length === 0) return null

  const hfRow = rows.find((row) => isHealthFactorMetric(row.label, row.id))
  const hfValue = parseHealthFactorValue(hfRow?.after ?? hfRow?.value)
  const detailRows = rows.filter((row) => !isHealthFactorMetric(row.label, row.id))

  return (
    <div className="space-y-3" data-testid="action-metrics-block">
      {hfRow ? (
        <ActionCard className="p-4" data-testid="action-health-factor-card">
          <ActionHealthFactorBar value={hfValue} label={hfRow.label} />
        </ActionCard>
      ) : null}

      {detailRows.length > 0 ? (
        <ActionCard className="overflow-hidden">
          <div className="divide-y divide-border/80">
            {detailRows.map((row) => (
              <ActionMetricRow
                key={row.id ?? row.label}
                id={row.id}
                label={row.label}
                value={row.value}
                before={row.before}
                after={row.after}
                tone={row.tone}
                tokenSymbols={row.tokenSymbols}
                tooltip={row.tooltip}
                liveUsd={row.liveUsd}
              />
            ))}
          </div>
        </ActionCard>
      ) : null}
    </div>
  )
}
