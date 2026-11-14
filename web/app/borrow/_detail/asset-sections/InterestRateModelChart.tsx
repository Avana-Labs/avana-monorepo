"use client"

import * as React from "react"
import type { InterestRateCurve, InterestRateModelProbe } from "@/app/lib/borrow-detail/interest-rate-curve"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { formatCompactUsd } from "@/app/lib/borrow-market-rows"
import { cn } from "@/lib/utils"
import { formatPercent } from "@/app/lib/format"

const X_TICKS = [0, 25, 50, 75, 100]
const VIEW_W = 640
const VIEW_H = 300
const PLOT_LEFT = 52
const PLOT_RIGHT = 624
const PLOT_TOP = 40
const PLOT_BOTTOM = 264

function plotX(utilization: number) {
  return PLOT_LEFT + (utilization / 100) * (PLOT_RIGHT - PLOT_LEFT)
}

function plotY(apr: number, maxApr: number) {
  return PLOT_BOTTOM - (apr / Math.max(maxApr, 1e-9)) * (PLOT_BOTTOM - PLOT_TOP)
}

function snapUtilization(raw: number) {
  return Math.round(Math.min(100, Math.max(0, raw)) * 10) / 10
}

function aprAlongCurve(curve: InterestRateCurve, utilization: number): number {
  const lo = Math.floor(utilization)
  const hi = Math.ceil(utilization)
  const lowApr = curve.points.find((point) => point.utilization === lo)?.apr
  const highApr = curve.points.find((point) => point.utilization === hi)?.apr
  if (lowApr == null) return highApr ?? 0
  if (highApr == null || lo === hi) return lowApr
  return lowApr + (highApr - lowApr) * (utilization - lo)
}

type Props = {
  curve: InterestRateCurve
  currentUtilization: number
  probe: InterestRateModelProbe | null
  onProbeUtilization: (utilizationPct: number | null) => void
  className?: string
}

export function InterestRateModelChart({ curve, currentUtilization, probe, onProbeUtilization, className }: Props) {
  const { t } = useTranslation()
  const shellRef = React.useRef<HTMLDivElement | null>(null)

  const pathD = React.useMemo(
    () =>
      curve.points
        .map((point, index) => {
          const x = plotX(point.utilization)
          const y = plotY(point.apr, curve.maxApr)
          return `${index === 0 ? "M" : "L"}${x.toFixed(2)} ${y.toFixed(2)}`
        })
        .join(" "),
    [curve],
  )

  const currentX = plotX(curve.currentUtilization)
  const currentY = plotY(aprAlongCurve(curve, curve.currentUtilization), curve.maxApr)
  const optimalX = plotX(curve.optimalUtilization)

  const hoverUtil = probe?.utilizationPct ?? null
  const hoverX = hoverUtil == null ? null : plotX(hoverUtil)
  const hoverY = hoverUtil == null || probe == null ? null : plotY(probe.borrowAprPct, curve.maxApr)

  const setPointerUtilization = (event: React.PointerEvent<HTMLDivElement>) => {
    const rect = event.currentTarget.getBoundingClientRect()
    const plotWidthPx = Math.max(1, rect.width * ((PLOT_RIGHT - PLOT_LEFT) / VIEW_W))
    const plotLeftPx = rect.width * (PLOT_LEFT / VIEW_W)
    const ratio = Math.min(1, Math.max(0, (event.clientX - rect.left - plotLeftPx) / plotWidthPx))
    onProbeUtilization(snapUtilization(ratio * 100))
  }

  const clearPointer = () => onProbeUtilization(null)

  const tooltipLeftPct =
    hoverX == null ? 50 : Math.min(86, Math.max(14, ((hoverX - PLOT_LEFT) / (PLOT_RIGHT - PLOT_LEFT)) * 100))

  return (
    <div
      ref={shellRef}
      className={cn("relative min-w-0 rounded-radius-md bg-muted/30 dark:bg-white/[0.03]", className)}
      data-testid="interest-rate-model-chart"
    >
      <div
        className="relative h-[260px] w-full cursor-crosshair touch-none sm:h-[300px] lg:h-full lg:min-h-[300px]"
        onPointerMove={setPointerUtilization}
        onPointerLeave={clearPointer}
        onPointerDown={setPointerUtilization}
      >
        <svg
          viewBox={`0 0 ${VIEW_W} ${VIEW_H}`}
          className="pointer-events-none absolute inset-0 h-full w-full select-none"
          role="img"
          aria-label={t("Borrow APR versus utilization")}
        >
          {curve.yTicks.map((tick) => {
            const y = plotY(tick, curve.maxApr)
            return (
              <g key={`y-${tick}`}>
                <line
                  x1={PLOT_LEFT}
                  x2={PLOT_RIGHT}
                  y1={y}
                  y2={y}
                  stroke="currentColor"
                  strokeOpacity={0.12}
                  strokeDasharray="1 5"
                  className="text-foreground"
                />
                <text
                  x={PLOT_LEFT - 10}
                  y={y}
                  textAnchor="end"
                  dominantBaseline="middle"
                  className="fill-muted-foreground text-[11px]"
                >
                  {tick}%
                </text>
              </g>
            )
          })}

          {X_TICKS.map((tick) => (
            <text
              key={`x-${tick}`}
              x={plotX(tick)}
              y={VIEW_H - 12}
              textAnchor="middle"
              className="fill-muted-foreground text-[11px]"
            >
              {tick}%
            </text>
          ))}

          <path
            d={pathD}
            fill="none"
            className="text-[hsl(var(--brand))]"
            stroke="currentColor"
            strokeWidth={3.5}
            strokeLinejoin="round"
            strokeLinecap="round"
          />

          <line
            x1={optimalX}
            x2={optimalX}
            y1={PLOT_TOP + 10}
            y2={PLOT_BOTTOM}
            stroke="rgba(1, 170, 207, 0.55)"
            strokeWidth={1.5}
            strokeDasharray="5 5"
          />
          <line
            x1={currentX}
            x2={currentX}
            y1={PLOT_TOP + 24}
            y2={PLOT_BOTTOM}
            stroke="rgba(1, 170, 207, 0.95)"
            strokeWidth={1.5}
            strokeDasharray="5 5"
          />
          <circle cx={currentX} cy={currentY} r={4.5} className="fill-[hsl(var(--brand))]" />

          {hoverX != null && hoverY != null ? (
            <>
              <line
                x1={hoverX}
                x2={hoverX}
                y1={PLOT_TOP}
                y2={PLOT_BOTTOM}
                stroke="currentColor"
                strokeOpacity={0.45}
                strokeWidth={1.25}
                className="text-foreground"
              />
              <circle
                cx={hoverX}
                cy={hoverY}
                r={5}
                className="fill-[hsl(var(--brand))] stroke-background"
                strokeWidth={2}
              />
            </>
          ) : null}

          <text x={optimalX} y={PLOT_TOP} textAnchor="middle" className="fill-muted-foreground text-[12px] font-medium">
            {t("Optimal")}
          </text>
          <text
            x={currentX}
            y={PLOT_TOP + 16}
            textAnchor="middle"
            className="fill-muted-foreground text-[12px] font-medium"
          >
            {t("Current {value}%").replace("{value}", formatPercent(currentUtilization, { dp: 2 }).replace("%", ""))}
          </text>
        </svg>

        {probe && hoverX != null ? (
          <div
            className="pointer-events-none absolute top-3 z-10 min-w-[168px] -translate-x-1/2 rounded-radius-md border border-border bg-background/95 px-3 py-2.5 shadow-sm backdrop-blur-sm dark:border-white/10 dark:bg-background/90"
            style={{ left: `${tooltipLeftPct}%` }}
            data-testid="interest-rate-model-tooltip"
          >
            <div className="text-[12px] text-muted-foreground">{t("Utilization Rate")}</div>
            <div className="mt-0.5 font-data text-[14px] font-medium tabular-nums text-foreground">
              {formatPercent(probe.utilizationPct, { dp: 1 })}
            </div>
            <div className="mt-2 flex items-center gap-1.5 text-[12px] text-muted-foreground">
              <span className="inline-block size-2 rounded-[2px] bg-[hsl(var(--brand))]" aria-hidden />
              {t("Borrow APY")}
            </div>
            <div className="mt-0.5 font-data text-[14px] font-medium tabular-nums text-foreground">
              {formatPercent(probe.borrowAprPct)}
            </div>
            <div className="mt-2 text-[11px] leading-snug text-muted-foreground">
              {t("Borrow amount to reach {value} Util.").replace(
                "{value}",
                formatPercent(probe.utilizationPct, { dp: 1 }),
              )}
            </div>
            <div className="mt-0.5 font-data text-[13px] font-medium tabular-nums text-foreground">
              {formatCompactUsd(probe.borrowDeltaUsd)}
            </div>
          </div>
        ) : null}
      </div>
    </div>
  )
}
