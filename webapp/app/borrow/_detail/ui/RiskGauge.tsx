"use client"

import * as React from "react"
import { cn } from "@/lib/utils"
import type { RiskLevel } from "@/app/lib/borrow-detail"

type RiskGaugeProps = {
  /** Score 0..100 (higher = riskier). */
  score: number
  level: RiskLevel
  /** Optional headline e.g. "Moderate risk" shown under the score. */
  label?: string
  /** Overall gauge width in px. */
  size?: number
  className?: string
  /** Number of radial ticks across the half-circle. */
  ticks?: number
}

const LEVEL_COLOR: Record<RiskLevel, string> = {
  low: "text-success",
  moderate: "text-warning",
  elevated: "text-warning",
  high: "text-danger",
}

const LEVEL_STROKE: Record<RiskLevel, string> = {
  low: "stroke-success",
  moderate: "stroke-warning",
  elevated: "stroke-warning",
  high: "stroke-danger",
}

/**
 * Half-circle tick-mark gauge. Renders N radial ticks across a 180° arc and
 * fills those up to `score` with the level color; remaining ticks are muted.
 */
export function RiskGauge({ score, level, label, size = 220, ticks = 44, className }: RiskGaugeProps) {
  const clamped = Number.isFinite(score) ? Math.max(0, Math.min(100, score)) : 0

  // SVG coordinate system
  const W = 220
  const H = 140
  const cx = W / 2
  const cy = 118 // baseline
  const rOuter = 98
  const rInner = 76
  const tickW = 3

  const filledCount = Math.round((clamped / 100) * ticks)

  // Angles sweep from 180° (left, 0 score) to 0° (right, 100 score).
  const angleFor = (i: number) => Math.PI * (1 - i / (ticks - 1))
  const toXY = (angle: number, r: number) => [cx + Math.cos(angle) * r, cy - Math.sin(angle) * r] as const

  return (
    <figure
      role="img"
      aria-label={`Risk gauge: ${clamped} out of 100 (${level})`}
      className={cn("flex flex-col items-center", className)}
      data-risk-score={clamped}
      data-risk-level={level}
    >
      <svg width={size} height={(size * H) / W} viewBox={`0 0 ${W} ${H}`} className="overflow-visible">
        {Array.from({ length: ticks }).map((_, i) => {
          const a = angleFor(i)
          const [x1, y1] = toXY(a, rInner)
          const [x2, y2] = toXY(a, rOuter)
          const active = i < filledCount
          return (
            <line
              key={i}
              x1={x1.toFixed(2)}
              y1={y1.toFixed(2)}
              x2={x2.toFixed(2)}
              y2={y2.toFixed(2)}
              strokeWidth={tickW}
              strokeLinecap="round"
              className={cn("transition-colors", active ? LEVEL_STROKE[level] : "stroke-muted-foreground/15")}
            />
          )
        })}

        {/* Center score */}
        <text
          x={cx}
          y={cy - 18}
          textAnchor="middle"
          className="fill-foreground font-data font-normal tabular-nums"
          style={{ fontSize: 34, letterSpacing: "-0.02em" }}
        >
          {clamped}
        </text>
        <text
          x={cx + 30}
          y={cy - 18}
          textAnchor="start"
          className="fill-muted-foreground font-data tabular-nums"
          style={{ fontSize: 13 }}
        >
          /100
        </text>

        {/* Endpoint labels */}
        <text
          x={cx - rOuter - 2}
          y={cy + 14}
          textAnchor="middle"
          className="fill-muted-foreground font-data tabular-nums"
          style={{ fontSize: 11 }}
        >
          0
        </text>
        <text
          x={cx + rOuter + 2}
          y={cy + 14}
          textAnchor="middle"
          className="fill-muted-foreground font-data tabular-nums"
          style={{ fontSize: 11 }}
        >
          100
        </text>
      </svg>
      {label ? <figcaption className={cn("-mt-1 text-xs font-medium", LEVEL_COLOR[level])}>{label}</figcaption> : null}
    </figure>
  )
}
