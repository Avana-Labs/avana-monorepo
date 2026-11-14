/**
 * Detail-level presentational formatters shared by both the deterministic
 * fallback builders and the Convex overlay path.
 */

export function formatOraclePrice(value: number): string {
  if (!Number.isFinite(value)) return "—"
  // Force en-US grouping: the currency switcher's redenomination regex parses this en-US
  // format, so a locale-dependent grouping (e.g. "1.234,56") would fail to re-denominate.
  if (value >= 100) return `$${value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
  if (value >= 1) return `$${value.toFixed(4)}`
  return `$${value.toFixed(6)}`
}

/**
 * Pair spot rate WITHOUT a currency symbol — the base leg priced in the quote leg's own units
 * (callers append the quote symbol, e.g. "33.71 WETH"). Deliberately not "$"-prefixed: the rate
 * is quote-denominated, not USD, so a "$" would misread it (the cbBTC/WETH "$33.75" bug).
 */
export function formatPairRate(rate: number): string {
  if (!Number.isFinite(rate)) return "—"
  if (rate >= 1) return rate.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  return rate.toFixed(6)
}
