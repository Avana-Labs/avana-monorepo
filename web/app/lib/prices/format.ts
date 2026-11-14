/**
 * Shared formatting for the real token-price oracle (Convex `tokenPrices`, sourced
 * from DefiLlama). Used server-side (asset detail "Price") and client-side (the
 * borrow-list price-under-logos). Pure — no React, no server-only imports.
 */

/** Normalize a token symbol to the oracle's key (lowercase base id, e.g. "WETH" → "weth"). */
export function priceKey(symbol: string): string {
  return symbol.trim().toLowerCase()
}

/** Format a USD token price: "$1,612.87", "$1.00", "$0.9997" (more precision under $1). */
export function formatTokenPrice(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return "—"
  // Locale MUST be pinned to en-US: the currency switcher (redenominateCompactUsd) only parses
  // en-US grouping, so a locale-derived "$1.612,87" silently stays in USD.
  if (value >= 1) return `$${value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
  return `$${value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 4 })}`
}
