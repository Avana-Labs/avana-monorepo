import { formatCompactUsd, formatUsdExact } from "@/app/lib/borrow-market-rows"

/**
 * Shared percent/APY formatting so every surface uses one decimal convention.
 *
 * Values are already expressed as percentages (e.g. `5.3` → `"5.30%"`), not
 * ratios. Asset APY/APR values render at 2 decimals everywhere; callers that
 * need a different precision (utilization, coarse hero deltas) pass `dp`.
 *
 * Pure — no React, no server-only imports — so it is safe on both client and
 * server. Prefer this over inline `.toFixed()` for any user-facing percent.
 */
export function formatPercent(value: number, opts: { dp?: number; sign?: boolean } = {}): string {
  const { dp = 2, sign = false } = opts
  if (!Number.isFinite(value)) return "—"
  const body = value.toFixed(dp)
  return sign && value > 0 ? `+${body}%` : `${body}%`
}

/** Canonical asset APY/APR convention: 2 decimals (e.g. `"5.30%"`). */
export function formatApy(value: number): string {
  return formatPercent(value, { dp: 2 })
}

/** Canonical exact USD display (currency-aware). */
export const formatUsd = formatUsdExact

export { formatCompactUsd, formatUsdExact }
