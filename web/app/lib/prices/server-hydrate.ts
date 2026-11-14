import "server-only"
import { unstable_cache } from "next/cache"
import { fetchTokenPrices } from "./server-snapshot"
import { setCanonicalPrices } from "./canonical"
import { waitForServerSeed } from "@/app/lib/performance/server-seed"
import { reportServerFetchFailure } from "@/app/lib/detail-page/report-server-fetch-failure"

/**
 * Cross-request cache for the oracle round-trip. The root layout awaits the price seed on every
 * render; without this each request blocks on a fresh Convex query — a per-request TTFB tax.
 * Prices are decorative and tolerate a short staleness window, so serve a cached value and
 * revalidate in the background every 60s. The client overlay still refreshes live once mounted.
 * `fetchTokenPrices` reads no request-specific data (a plain Convex query), so it is cache-safe.
 */
const getCachedTokenPrices = unstable_cache(fetchTokenPrices, ["server-token-prices"], { revalidate: 60 })

/**
 * Fetch the live oracle prices ONCE on the server: hydrate the server-side canonical store
 * (so server-rendered surfaces are live) AND return the price map (keys = lowercase symbol,
 * i.e. `priceKey` form) so the root layout can seed the client `TokenPricesContext` with it.
 *
 * This seed is what makes CLIENT-rendered prices (the lend list, borrow table, action pages)
 * live even though the realtime Convex subscription only mounts on authenticated product
 * routes — the client no longer depends on that subscription to escape the fixture. Returns an
 * empty map when no deployment is configured / it is unreachable (client falls back to fixture).
 */
export async function loadServerTokenPrices(): Promise<Record<string, number>> {
  try {
    const prices = await waitForServerSeed(getCachedTokenPrices(), null)
    if (prices) {
      setCanonicalPrices(prices)
      return prices
    }
  } catch (error) {
    // Leave the fixture in place; the client overlay still refreshes once mounted.
    reportServerFetchFailure("loadServerTokenPrices", error)
  }
  return {}
}
