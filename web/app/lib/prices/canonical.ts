import { priceKey } from "./format"
import { PRICE_FIXTURE } from "./price-fixture"

/**
 * The SINGLE per-token USD basis every surface reads (lists, detail tiles, pool pair prices, swap
 * catalog, engine valuation via sandboxBaselinePriceUsd), so a token can never show two prices one
 * click apart. Deterministic PRICE_FIXTURE, overlaid at runtime by the live Convex oracle; a symbol
 * covered by neither resolves to `undefined`, never a fabricated number.
 */

// Two INDEPENDENT overlays (crypto oracle, stock feed) stay separate layers and are both re-applied
// on every recompute, so refreshing one never clobbers the other's quotes. Stock wins on overlap.
let oracleLayer: Record<string, number> = {}
let stockLayer: Record<string, number> = {}

/** UPPERCASE symbol → USD price. Fixture, overlaid by the oracle then the stock layer. */
let priceStore: Record<string, number> = { ...PRICE_FIXTURE }

function recompute(): void {
  priceStore = { ...PRICE_FIXTURE, ...oracleLayer, ...stockLayer }
}

function normalizePrices(next: Record<string, number>): Record<string, number> {
  const out: Record<string, number> = {}
  for (const [symbol, price] of Object.entries(next)) {
    if (Number.isFinite(price) && price > 0) out[symbol.toUpperCase()] = price
  }
  return out
}

/**
 * Overlay live crypto oracle prices (client-only). Sits on TOP of the fixture so a partial oracle
 * response still resolves covered majors. Non-finite/non-positive quotes are dropped.
 */
export function setCanonicalPrices(next: Record<string, number>): void {
  oracleLayer = normalizePrices(next)
  recompute()
}

/** Overlay live tokenized-stock prices. Independent of the crypto oracle layer. */
export function setStockPrices(next: Record<string, number>): void {
  stockLayer = normalizePrices(next)
  recompute()
}

/** The live stock layer keyed by `priceKey` (lowercased), for merging into the reactive context. */
export function stockPriceMap(): Record<string, number> {
  const map: Record<string, number> = {}
  for (const [symbol, priceUsd] of Object.entries(stockLayer)) map[priceKey(symbol)] = priceUsd
  return map
}

/** Reset the store to the deterministic fixture (used by test setup to prevent cross-test leakage). */
export function resetCanonicalPrices(): void {
  oracleLayer = {}
  stockLayer = {}
  recompute()
}

/**
 * USD price for a symbol, or `undefined` when neither oracle nor fixture covers it. Deliberately
 * strict (no `?? 1`) so callers fall back to their own label instead of rendering "$1.00" for an
 * unpriced asset. Engine code needing a guaranteed number uses `sandboxBaselinePriceUsd`.
 */
export function canonicalPriceUsd(symbol: string): number | undefined {
  if (!symbol) return undefined
  return priceStore[symbol.toUpperCase()]
}

/** Canonical prices keyed by `priceKey` (lowercased), the shape `injectPoolOraclePrice` consumes. */
export function canonicalPriceMap(): Record<string, number> {
  const map: Record<string, number> = {}
  for (const [symbol, priceUsd] of Object.entries(priceStore)) {
    map[priceKey(symbol)] = priceUsd
  }
  return map
}
