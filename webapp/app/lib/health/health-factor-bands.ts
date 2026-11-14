import type { ActionMetricTone } from "@/app/lib/action-system/contracts"

/**
 * Single source of truth for health-factor band, label, tone and colour. EVERY surface must
 * derive HF presentation from here, so one number never reads "Safe/green" on one screen and
 * "Watch/orange" on another. Bands sit deliberately above the engine's 1.0 liquidation floor
 * to warn early: danger < 1.2, watch < 1.75, moderate < 2.5, safe ≥ 2.5, unknown for null/NaN.
 */

type HealthBandId = "safe" | "moderate" | "watch" | "danger" | "unknown"

type HealthBand = {
  id: HealthBandId
  /** Inclusive lower bound on the health-factor axis. */
  min: number
  /** Exclusive upper bound. */
  max: number
  /** Canonical, translation-key-friendly label (Title case). */
  label: string
  /** Coarse tone used by action metric rows / badges. */
  tone: ActionMetricTone
  /** Single text-colour class used by dashboard tables + borrow-sim. */
  textClass: string
  /** Classes for the small status pill on home / dashboard cards. */
  status: { dotClass: string; textClass: string; barClass: string }
  /** Classes for the health-factor position bar fill + thumb. */
  bar: { text: string; fill: string; border: string }
  /** Segment colour for the labelled zone strip under the bar. */
  segmentColor: string
  /** Relative width of this band's segment in the zone strip (bands sum to 100). */
  widthPct: number
}

// Ordered safest → riskiest so the labelled zone strip reads left (safe) to
// right (liquidation).
export const HEALTH_BANDS: readonly HealthBand[] = [
  {
    id: "safe",
    min: 2.5,
    max: Number.POSITIVE_INFINITY,
    label: "Safe",
    tone: "positive",
    textClass: "text-success",
    status: { dotClass: "bg-emerald-500", textClass: "text-success", barClass: "bg-emerald-500" },
    bar: { text: "text-success", fill: "bg-success", border: "border-success" },
    segmentColor: "bg-emerald-500",
    widthPct: 40,
  },
  {
    id: "moderate",
    min: 1.75,
    max: 2.5,
    label: "Moderate",
    tone: "warning",
    textClass: "text-amber-700 dark:text-amber-300",
    status: { dotClass: "bg-amber-400", textClass: "text-amber-600", barClass: "bg-amber-400" },
    bar: { text: "text-amber-600", fill: "bg-amber-400", border: "border-amber-400" },
    segmentColor: "bg-amber-400",
    widthPct: 22,
  },
  {
    id: "watch",
    min: 1.2,
    max: 1.75,
    label: "Watch",
    tone: "warning",
    textClass: "text-orange-700 dark:text-orange-300",
    status: { dotClass: "bg-orange-500", textClass: "text-orange-600", barClass: "bg-orange-500" },
    bar: { text: "text-orange-600", fill: "bg-orange-500", border: "border-orange-500" },
    segmentColor: "bg-orange-500",
    widthPct: 20,
  },
  {
    id: "danger",
    min: 0,
    max: 1.2,
    label: "At risk",
    tone: "danger",
    textClass: "text-rose-700 dark:text-rose-300",
    status: { dotClass: "bg-rose-500", textClass: "text-rose-600", barClass: "bg-rose-500" },
    bar: { text: "text-danger", fill: "bg-danger", border: "border-danger" },
    segmentColor: "bg-rose-500",
    widthPct: 18,
  },
] as const

const UNKNOWN_HEALTH_BAND: HealthBand = {
  id: "unknown",
  min: Number.NaN,
  max: Number.NaN,
  label: "Unknown",
  tone: "default",
  textClass: "text-muted-foreground",
  status: { dotClass: "bg-muted-foreground", textClass: "text-muted-foreground", barClass: "bg-muted" },
  bar: { text: "text-muted-foreground", fill: "bg-muted", border: "border-border" },
  segmentColor: "bg-muted-foreground/50",
  widthPct: 0,
}

/** Resolve a health factor to its band. `null`/`NaN` → unknown; `Infinity` → safe. */
export function healthFactorBand(hf: number | null | undefined): HealthBand {
  if (hf == null || Number.isNaN(hf)) return UNKNOWN_HEALTH_BAND
  if (!Number.isFinite(hf)) return HEALTH_BANDS[0]
  return HEALTH_BANDS.find((band) => hf >= band.min && hf < band.max) ?? HEALTH_BANDS[HEALTH_BANDS.length - 1]
}

/** Canonical label for a health factor ("Safe" / "Moderate" / "Watch" / "At risk"). */
export function healthFactorLabel(hf: number | null | undefined): string {
  return healthFactorBand(hf).label
}

/** Parse a formatted HF string ("1.60", "∞", "—") back to a number for banding. */
export function parseHealthFactorValue(value: string | undefined | null): number | null {
  if (!value || value === "—") return null
  if (value.includes("∞")) return Number.POSITIVE_INFINITY
  const parsed = Number.parseFloat(value.replace(/[^\d.]/g, ""))
  return Number.isFinite(parsed) ? parsed : null
}
