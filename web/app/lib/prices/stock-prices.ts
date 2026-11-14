import { registryStockPriceIds } from "@/app/lib/tokens/registry"
import { setStockPrices } from "./canonical"

/**
 * Live tokenized-stock prices for the canonical price store. Mirrors the currency FX path
 * (see app/lib/currency/exchange-rates.ts): the client hits a same-origin route that fetches a free
 * stock-price provider server-side, then overlays the quotes on top of the deterministic fixture.
 *
 * The fixture (price-fixture.ts, seeded from the token registry) stays the fallback, so an offline
 * or failed fetch never leaves a stock unpriced. Private names with no public quote (SpaceX / SPCX)
 * carry `priceSource: "fixture"` in the registry and are never requested here.
 */
export const STOCK_PRICES_UPDATED_EVENT = "avana:stock-prices-updated"
export const STOCK_PRICE_REFRESH_MS = 5 * 60 * 1000 // 5 minutes

const ENDPOINT = "/api/stock-prices"
const CACHE_KEY = "avana-stock-prices"
const CACHE_TTL_MS = 5 * 60 * 1000

// UPPERCASE registry symbol → API ticker (e.g. NVDA→NVDA, NVDAC→NVDA). SPCX is excluded upstream.
const SYMBOL_TICKERS = registryStockPriceIds()

type CachedPrices = { fetchedAt: number; prices: Record<string, number> }

/** Map an API `{TICKER: price}` response onto every registry symbol sharing that ticker (NVDA + NVDAc). */
function expandToSymbols(tickerPrices: Record<string, number>): Record<string, number> {
  const out: Record<string, number> = {}
  for (const [symbol, ticker] of Object.entries(SYMBOL_TICKERS)) {
    const price = tickerPrices[ticker.toUpperCase()]
    if (typeof price === "number" && Number.isFinite(price) && price > 0) out[symbol] = price
  }
  return out
}

function notifyUpdated(): void {
  if (typeof window !== "undefined") window.dispatchEvent(new Event(STOCK_PRICES_UPDATED_EVENT))
}

function readCache(): CachedPrices | null {
  if (typeof window === "undefined") return null
  try {
    const raw = window.localStorage.getItem(CACHE_KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw) as CachedPrices
    if (!parsed || typeof parsed.fetchedAt !== "number" || !parsed.prices) return null
    return parsed
  } catch {
    return null
  }
}

/** Apply the last cached live stock prices synchronously (client only). Returns true if any applied. */
export function applyCachedStockPrices(): boolean {
  const cached = readCache()
  if (!cached) return false
  setStockPrices(cached.prices)
  notifyUpdated()
  return Object.keys(cached.prices).length > 0
}

/**
 * Fetch live tokenized-stock prices and overlay them on the canonical store. Skips the network when
 * the cache is still fresh (unless `force`). Never throws — on any failure the fixture (or last
 * cache) stays in effect. Resolves true only when fresh prices were applied from the network.
 */
export async function fetchStockPrices(options?: { force?: boolean }): Promise<boolean> {
  if (typeof window === "undefined") return false

  if (!options?.force) {
    const cached = readCache()
    if (cached && Date.now() - cached.fetchedAt < CACHE_TTL_MS) {
      setStockPrices(cached.prices)
      notifyUpdated()
      return false
    }
  }

  try {
    const res = await fetch(ENDPOINT, { cache: "no-store" })
    if (!res.ok) return false
    const data = (await res.json()) as { result?: string; prices?: Record<string, number> | null }
    if (data.result !== "success" || !data.prices) return false

    const prices = expandToSymbols(data.prices)
    if (Object.keys(prices).length === 0) return false

    setStockPrices(prices)
    notifyUpdated()
    try {
      window.localStorage.setItem(CACHE_KEY, JSON.stringify({ fetchedAt: Date.now(), prices } satisfies CachedPrices))
    } catch {
      // Storage full / disabled — prices are still applied in-memory for this session.
    }
    return true
  } catch {
    return false
  }
}
