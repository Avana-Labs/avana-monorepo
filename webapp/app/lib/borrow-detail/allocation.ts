/**
 * Shared helpers used by both detail pages:
 * - risk premium bucketing (keeps the pools-table column consistent with the
 *   detail page risk card)
 * - the venue label of an allocation row
 * - compact formatters
 */

import type { BorrowPoolRow } from "@/app/lib/borrow-market-rows"
import type { RiskLevel } from "./types"
import { formatPercent } from "@/app/lib/format"

/**
 * Maps a risk premium (bps) to a qualitative bucket. The bounds are kept in
 * one place so the table pill, the detail gauge, and the breakdown card never
 * disagree. Numbers are inclusive on the lower bound.
 */
export function riskLevelFromBps(bps: number): RiskLevel {
  if (bps < 40) return "low"
  if (bps < 100) return "moderate"
  if (bps < 180) return "elevated"
  return "high"
}

/** Human label for the risk bucket. */
export function riskLevelLabel(level: RiskLevel): string {
  switch (level) {
    case "low":
      return "Low"
    case "moderate":
      return "Moderate"
    case "elevated":
      return "Elevated"
    case "high":
      return "High"
  }
}

/**
 * Gauge score (0..100). Clamped so visual designers can trust the bounds.
 * 25 bps → ~12, 90 bps → ~45, 180 bps → ~70, 300+ bps → ~92.
 */
export function riskScoreFromBps(bps: number): number {
  const mapped = 100 * (1 - Math.exp(-bps / 160))
  return Math.round(Math.max(2, Math.min(98, mapped)))
}

/** Venue label for an allocation pool (dex label, falling back to the venue string). */
export function allocationVenueLabel(pool: Pick<BorrowPoolRow, "dexLabel" | "venue">): string {
  return pool.dexLabel || pool.venue
}

// -------------------------------------------------------------------------
// Compact formatters
// -------------------------------------------------------------------------

/** Compact percentage label with fixed digits (e.g. "68.4%"). */
export function formatPct(value: number, digits = 1): string {
  return formatPercent(value, { dp: digits })
}

/** Compact bps label (e.g. "+0.80%"). */
export function formatBpsAsPct(bps: number): string {
  if (!Number.isFinite(bps)) return "—"
  return `${bps >= 0 ? "+" : ""}${(bps / 100).toFixed(2)}%`
}
