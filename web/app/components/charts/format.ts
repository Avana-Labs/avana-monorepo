import type { ChartValueFormat } from "./types"
import { getActiveCurrency, toActive } from "@/app/lib/currency/active-rate"

/** Sign prefix that belongs BEFORE the currency symbol ("-$1.50K", not "$-1.50K"). */
function signOf(value: number): string {
  return value < 0 ? "-" : ""
}

function formatCompactUsd(value: number): string {
  const { symbol } = getActiveCurrency()
  value = toActive(value)
  const sign = signOf(value)
  const abs = Math.abs(value)
  if (abs >= 1_000_000_000) return `${sign}${symbol}${(abs / 1_000_000_000).toFixed(2)}B`
  if (abs >= 1_000_000) return `${sign}${symbol}${(abs / 1_000_000).toFixed(2)}M`
  if (abs >= 1_000) return `${sign}${symbol}${(abs / 1_000).toFixed(2)}K`
  return `${sign}${symbol}${abs.toFixed(2)}`
}

function formatCompactAxis(value: number): string {
  const { symbol } = getActiveCurrency()
  value = toActive(value)
  const sign = signOf(value)
  const abs = Math.abs(value)
  if (abs >= 1_000_000_000) return `${sign}${symbol}${(abs / 1_000_000_000).toFixed(1)}B`
  if (abs >= 1_000_000) return `${sign}${symbol}${(abs / 1_000_000).toFixed(1)}M`
  if (abs >= 1_000) return `${sign}${symbol}${(abs / 1_000).toFixed(1)}K`
  return `${sign}${symbol}${Math.round(abs)}`
}

/**
 * Label for a chart point. Date-only keys ("2026-09-21") are UTC days, so they are formatted in
 * UTC: formatting them in the viewer's zone put every point a day early west of UTC (and a
 * 1st-of-month point in the previous month). Timestamps keep the viewer's local clock.
 */
export function formatChartPointLabel(value: string, range?: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  if (range === "1D" || value.includes("T")) {
    return new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit" }).format(date)
  }
  if (range === "1Y" || range === "ALL") {
    return new Intl.DateTimeFormat("en-US", { month: "short", year: "2-digit", timeZone: "UTC" }).format(date)
  }
  return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", timeZone: "UTC" }).format(date)
}

/** Tooltip + headline value formatting. */
export function formatChartValue(format: ChartValueFormat, value: number): string {
  switch (format) {
    case "percent":
      return `${value.toFixed(2)}%`
    case "ratio":
      // A plain unitless ratio (e.g. a health factor 1.60). Not a currency, not a
      // percent — rendered with an "x" suffix so it reads as a multiple.
      return `${value.toFixed(2)}x`
    case "usdCompact":
      return formatCompactUsd(value)
    case "price":
    case "usd":
    default: {
      const active = toActive(value)
      return `${signOf(active)}${getActiveCurrency().symbol}${Math.abs(active).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
    }
  }
}

/** Y-axis tick formatting (shorter than the headline). */
export function formatChartAxis(format: ChartValueFormat, value: number): string {
  switch (format) {
    case "percent":
      return `${value.toFixed(value >= 10 ? 0 : 1)}%`
    case "ratio":
      return value.toFixed(value >= 10 ? 0 : 1)
    case "usdCompact":
      return formatCompactAxis(value)
    case "price":
    case "usd":
    default: {
      const active = toActive(value)
      return `${signOf(active)}${getActiveCurrency().symbol}${Math.round(Math.abs(active)).toLocaleString()}`
    }
  }
}
