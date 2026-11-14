import { priceKey } from "./format"

/**
 * The SINGLE per-token USD basis every surface reads (lists, detail tiles, pool pair prices, swap
 * catalog), so a token can never show two prices one click apart. Filled at runtime from the
 * Convex price snapshot; a symbol it does not cover resolves to `undefined`, never a fabricated
 * number.
 */

/** UPPERCASE symbol → USD price, from the live price snapshot. */
let priceStore: Record<string, number> = {}

function normalizePrices(next: Record<string, number>): Record<string, number> {
  const out: Record<string, number> = {}
  for (const [symbol, price] of Object.entries(next)) {
    if (Number.isFinite(price) && price > 0) out[symbol.toUpperCase()] = price
  }
  return out
}

/** Replace the store with live prices (client-only). Non-finite/non-positive quotes are dropped. */
export function setCanonicalPrices(next: Record<string, number>): void {
  priceStore = normalizePrices(next)
}

/** Empty the store (used by test setup to prevent cross-test leakage). */
export function resetCanonicalPrices(): void {
  priceStore = {}
}

/**
 * USD price for a symbol, or `undefined` when the live snapshot does not cover it. Deliberately
 * strict (no `?? 1`) so callers show their unavailable label instead of "$1.00".
 */
export function canonicalPriceUsd(symbol: string): number | undefined {
  if (!symbol) return undefined
  return priceStore[symbol.toUpperCase()]
}

/** Canonical prices keyed by `priceKey` (lowercased). */
export function canonicalPriceMap(): Record<string, number> {
  const map: Record<string, number> = {}
  for (const [symbol, priceUsd] of Object.entries(priceStore)) {
    map[priceKey(symbol)] = priceUsd
  }
  return map
}
