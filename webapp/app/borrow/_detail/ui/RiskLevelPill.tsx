"use client"

import * as React from "react"
import { cn } from "@/lib/utils"
import type { RiskLevel } from "@/app/lib/borrow-detail"
import { riskLevelLabel } from "@/app/lib/borrow-detail"

type RiskLevelPillProps = {
  level: RiskLevel
  className?: string
  /** Text prefix (e.g. "Risk:"). */
  prefix?: string
  /** Render with a small dot. Defaults to true. */
  withDot?: boolean
  size?: "sm" | "md"
}

const TONE: Record<RiskLevel, { bg: string; text: string; dot: string }> = {
  low: { bg: "bg-success/10", text: "text-success", dot: "bg-success" },
  moderate: { bg: "bg-warning/10", text: "text-warning", dot: "bg-warning" },
  elevated: { bg: "bg-warning/10", text: "text-warning", dot: "bg-warning" },
  high: { bg: "bg-danger/10", text: "text-danger", dot: "bg-danger" },
}

export function RiskLevelPill({ level, className, prefix, withDot = true, size = "sm" }: RiskLevelPillProps) {
  const tone = TONE[level]
  const sizeCls = size === "md" ? "h-6 text-[12px] px-2" : "h-5 text-[11px] px-1.5"
  return (
    <span
      className={cn("inline-flex items-center gap-1 rounded-xs font-medium", sizeCls, tone.bg, tone.text, className)}
      aria-label={`Risk level ${riskLevelLabel(level)}`}
      data-risk-level={level}
    >
      {withDot ? <span className={cn("size-1.5 rounded-full", tone.dot)} aria-hidden /> : null}
      {prefix ? <span className="font-medium opacity-80">{prefix}</span> : null}
      <span>{riskLevelLabel(level)}</span>
    </span>
  )
}
