"use client"

import type { ComponentProps } from "react"
import { cn } from "@/lib/utils"
import { clamp, take } from "@/lib/range"
import { mono, paper } from "@/lib/surfaces"

type ChartVariant = "area" | "line" | "bars"

const W = 300
const H = 88
const PAD = 6

function formatChartValue(value: string) {
  const match = /^\$([\d,]+(?:\.\d+)?)$/.exec(value.trim())
  if (!match) return value
  const amount = Number(match[1].replaceAll(",", ""))
  if (!Number.isFinite(amount)) return value
  const maximumFractionDigits = amount >= 1 ? 2 : amount >= 0.01 ? 4 : 6
  return `$${amount.toLocaleString("en-US", {
    minimumFractionDigits: amount >= 1 ? 2 : 0,
    maximumFractionDigits,
  })}`
}

const scale = (points: readonly number[]) => {
  const max = Math.max(...points, 1)
  const min = Math.min(...points, 0)
  const span = max - min || 1
  return (value: number) => H - PAD - ((value - min) / span) * (H - PAD * 2)
}

export function Chart({
  label,
  value,
  delta,
  points,
  visibleCount,
  variant = "area",
  className,
  ...props
}: Omit<ComponentProps<"div">, "children" | "label" | "value" | "delta" | "points" | "visibleCount" | "variant"> & {
  label: string
  value: string
  delta?: string
  points: readonly number[]
  visibleCount: number
  variant?: ChartVariant
}) {
  const shown = take(points, clamp(visibleCount, 1, points.length))
  const y = scale(points)
  const step = points.length > 1 ? (W - PAD * 2) / (points.length - 1) : 0
  const x = (i: number) => PAD + i * step

  const coords = shown.map((p, i) => ({ x: x(i), y: y(p) }))
  const line = coords.map((c) => `${c.x},${c.y}`).join(" ")
  const last = coords.at(-1)
  const area = last
    ? `M ${PAD},${H - PAD} ${coords.map((c) => `L ${c.x},${c.y}`).join(" ")} L ${last.x},${H - PAD} Z`
    : ""
  const lastIndex = shown.length - 1
  const falling = delta !== undefined && /^\s*[-−–]/.test(delta)
  const rising = delta !== undefined && !falling
  const displayValue = formatChartValue(value)

  return (
    <div
      data-slot="chart"
      className={cn(paper, "flex w-full max-w-sm flex-col gap-3 rounded-2xl p-4", className)}

      {...props}
    >
      <div className="flex items-baseline justify-between">
        <span className={cn(mono, "text-foreground/35")}>{label}</span>
        {delta !== undefined && (
          <span
            className={cn(
              mono,
              "tabular-nums",
              rising ? "text-emerald-600 dark:text-emerald-400" : "text-red-600 dark:text-red-400",
            )}
          >
            {delta}
          </span>
        )}
      </div>

      <span className="text-2xl font-medium tracking-tight tabular-nums">{displayValue}</span>

      <svg
        viewBox={`0 0 ${W} ${H}`}
        role="img"
        aria-label={`${label}: ${displayValue}`}
        className="h-[88px] w-full overflow-visible"
        preserveAspectRatio="none"
      >
        <line
          x1="0"
          x2={W}
          y1={H - PAD}
          y2={H - PAD}
          className="stroke-foreground/[0.08]"
          strokeWidth="1"
          vectorEffect="non-scaling-stroke"
        />
        {variant === "bars" ? (
          shown.map((p, i) => {
            const top = y(p)
            const barWidth = Math.max(2, step * 0.55)
            return (
              <rect
                key={i}
                x={x(i) - barWidth / 2}
                y={top}
                width={barWidth}
                height={Math.max(1, H - PAD - top)}
                rx="1.5"
                className={cn(
                  "fade-in animate-in fill-mode-both duration-300",
                  i === lastIndex ? "fill-blue-500 dark:fill-blue-400" : "fill-foreground/25",
                )}
                style={{ animationDelay: `${i * 40}ms` }}
              />
            )
          })
        ) : (
          <>
            {variant === "area" && shown.length > 1 && <path d={area} fill="rgb(59 130 246 / 0.1)" />}
            <polyline
              points={line}
              fill="none"
              strokeWidth="1.75"
              strokeLinecap="round"
              strokeLinejoin="round"
              vectorEffect="non-scaling-stroke"
              className="stroke-blue-500 dark:stroke-blue-400"
            />
            {last && <circle cx={last.x} cy={last.y} r="3" className="fill-blue-500 dark:fill-blue-400" />}
          </>
        )}
      </svg>
    </div>
  )
}
