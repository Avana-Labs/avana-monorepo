import type { CurrencyCode } from "@/app/components/display-preferences"
import { applyLiveRates, USD_PER_UNIT_BASELINE } from "@/app/lib/currency/rates"

/**
 * Live FX rates for the display-currency switcher. The app stores everything in
 * USD; this fetches real "units per 1 USD" rates so a non-USD selection shows the
 * amount at today's rate instead of the static baseline in `rates.ts`.
 *
 * Source: open.er-api.com — a free, key-less, CORS-enabled endpoint that returns
 * USD-based rates for 160+ currencies (updated daily). The baseline in `rates.ts`
 * remains the fallback when the network is unavailable, so the switcher never
 * breaks offline.
 */
const ENDPOINT = "/api/fx-rates"
const CACHE_KEY = "avana-fx-rates"
// Rates refresh at most this often; a fresh cache short-circuits the network so
// switching currencies stays instant on repeat visits.
const CACHE_TTL_MS = 6 * 60 * 60 * 1000 // 6 hours

// Only pull the currencies the switcher actually offers, keyed off the baseline.
const SUPPORTED = Object.keys(USD_PER_UNIT_BASELINE) as CurrencyCode[]

type LiveRateMap = Partial<Record<CurrencyCode, number>>
type CachedRates = { fetchedAt: number; rates: LiveRateMap }

function pickSupportedFxRates(raw: Record<string, unknown>): LiveRateMap {
  const out: LiveRateMap = {}
  for (const code of SUPPORTED) {
    const value = raw[code]
    if (typeof value === "number" && Number.isFinite(value) && value > 0) {
      out[code] = value
    }
  }
  return out
}

function readCache(): CachedRates | null {
  if (typeof window === "undefined") return null
  try {
    const raw = window.localStorage.getItem(CACHE_KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw) as CachedRates
    if (!parsed || typeof parsed.fetchedAt !== "number" || !parsed.rates) return null
    return parsed
  } catch {
    return null
  }
}

/**
 * Apply the last cached live rates synchronously (client only). Lets a repeat
 * visitor render in their currency at the last-known live rate immediately, before
 * the network round-trip. Returns true if any rates were applied.
 */
export function applyCachedLiveRates(): boolean {
  const cached = readCache()
  if (!cached) return false
  applyLiveRates(cached.rates)
  return Object.keys(cached.rates).length > 0
}

/**
 * Fetch live USD-based FX rates and overlay them on the baseline. Skips the
 * network when the cache is still fresh (unless `force`). Never throws — on any
 * failure the baseline (or last cache) stays in effect. Resolves true only when
 * fresh rates were applied from the network, so the caller can trigger a re-render.
 */
export async function fetchLiveRates(options?: { force?: boolean }): Promise<boolean> {
  if (typeof window === "undefined") return false

  if (!options?.force) {
    const cached = readCache()
    if (cached && Date.now() - cached.fetchedAt < CACHE_TTL_MS) {
      // Cache is fresh; make sure it's applied but don't hit the network.
      applyLiveRates(cached.rates)
      return false
    }
  }

  try {
    const res = await fetch(ENDPOINT, { cache: "no-store" })
    if (!res.ok) return false
    const data = (await res.json()) as { result?: string; rates?: Record<string, number> | null }
    if (data.result !== "success" || !data.rates) return false

    const rates = pickSupportedFxRates(data.rates)
    if (Object.keys(rates).length === 0) return false

    applyLiveRates(rates)
    try {
      window.localStorage.setItem(CACHE_KEY, JSON.stringify({ fetchedAt: Date.now(), rates } satisfies CachedRates))
    } catch {
      // Storage full / disabled — rates are still applied in-memory for this session.
    }
    return true
  } catch {
    return false
  }
}
