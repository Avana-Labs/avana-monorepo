"use client"

import { cn } from "@/lib/utils"

type Format = "percent" | "number" | "usd" | "bps"

type DeltaPillProps = {
  /** The delta value. Sign determines color. */
  value: number
  /** How to format the number. */
  format?: Format
  /** Which sign is "good" (emerald). Defaults to "up". */
  goodDirection?: "up" | "down"
  /**
   * Absolute magnitude above which the pill gets a stronger fill.
   * Matches Toss's "small move = muted, big move = loud" logic.
   */
  strongThreshold?: number
  /** Digits after the decimal when formatting. Default varies by format. */
  digits?: number
  /** Optional prefix/suffix text inside the pill (e.g. "24h"). */
  label?: string
  className?: string
  /** If true, render nothing when value rounds to zero. Default true. */
  hideZero?: boolean
}

function formatDelta(value: number, format: Format, digits?: number): string {
  const abs = Math.abs(value)
  switch (format) {
    case "percent": {
      const d = digits ?? 2
      return `${abs.toFixed(d)}%`
    }
    case "bps": {
      return `${abs.toFixed(digits ?? 0)} bps`
    }
    case "usd": {
      const d = digits ?? (abs < 1 ? 4 : 2)
      return `$${abs.toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d })}`
    }
    case "number":
    default: {
      const d = digits ?? 2
      return abs.toFixed(d)
    }
  }
}

/**
 * Compact directional pill showing a delta with tinted background.
 * Use next to live values to communicate "change since X".
 */
export function DeltaPill({
  value,
  format = "percent",
  goodDirection = "up",
  strongThreshold = Infinity,
  digits,
  label,
  className,
  hideZero = true,
}: DeltaPillProps) {
  if (!Number.isFinite(value)) return null
  const rounded = Number(value.toFixed(4))
  if (hideZero && rounded === 0) return null

  const direction: "up" | "down" | "flat" = rounded > 0 ? "up" : rounded < 0 ? "down" : "flat"
  const isGood = direction === goodDirection
  const isStrong = Math.abs(rounded) >= strongThreshold

  const tone =
    direction === "flat"
      ? "bg-muted text-muted-foreground"
      : isGood
        ? isStrong
          ? "bg-emerald-600 text-white"
          : "bg-emerald-500/10 text-success"
        : isStrong
          ? "bg-rose-600 text-white"
          : "bg-rose-500/10 text-rose-700 dark:text-rose-400"

  const sign = direction === "up" ? "+" : direction === "down" ? "−" : ""

  return (
    <span
      className={cn(
        "inline-flex items-center gap-1 rounded-full px-2 py-0.5 font-data text-[11px] font-normal leading-4 tabular-nums",
        tone,
        className,
      )}
    >
      <span>
        {sign}
        {formatDelta(rounded, format, digits)}
      </span>
      {label ? <span className="opacity-80">{label}</span> : null}
    </span>
  )
}
