"use client"

import * as React from "react"
import { hasConvexClient } from "@/app/lib/convex/market-liquidity-provider"
import { isLighthouseAuditMode } from "@/app/lib/test-mode"
import { priceKey } from "./format"
import { PRICE_FIXTURE } from "./price-fixture"
import { stockPriceMap } from "./canonical"
import {
  applyCachedStockPrices,
  fetchStockPrices,
  STOCK_PRICE_REFRESH_MS,
  STOCK_PRICES_UPDATED_EVENT,
} from "./stock-prices"

/**
 * Live token prices (base symbol → USD) from the Convex oracle, provided once and
 * read by the borrow-list cells (pair exchange rate / asset price under the logos).
 * Reading once here avoids a useQuery subscription per row. Degrades to an empty
 * map when no Convex client is mounted, so cells fall back to their static labels.
 */
export const TokenPricesContext = React.createContext<Record<string, number>>({})

/**
 * Price freshness, surfaced so the UI can warn when the refresh cron has stalled instead
 * of presenting last-known values as live. `stale` is false until the status query
 * resolves (don't flash a warning during the initial load) and when no Convex client is
 * mounted (static-label fallback, nothing to be stale about).
 */
export type PriceFreshness = {
  stale: boolean
  updatedAt: number | null
  ageMs: number | null
}
export type PriceStatus = {
  updatedAt: number | null
  staleAfterMs: number
  invalidAfterMs?: number
  count: number
}

export const PriceStatusContext = React.createContext<PriceStatus | undefined>(undefined)

/** What the realtime subscriber publishes: the seed+live price map and oracle freshness. */
export type LivePrices = { map: Record<string, number>; status: PriceStatus | undefined }

const ConvexTokenPricesSubscriber = React.lazy(() => import("./convex-token-prices"))

/** A stable lookup: symbol → USD price (undefined when unpriced). */
export function usePriceFor(): (symbol: string) => number | undefined {
  const map = React.useContext(TokenPricesContext)
  return React.useCallback((symbol: string) => map[priceKey(symbol)], [map])
}

/**
 * REACTIVE canonical price lookup for client components: the live oracle price from
 * context (re-renders when the overlay lands) with the deterministic PRICE_FIXTURE as a
 * fallback. Use this instead of the non-reactive `canonicalPriceUsd` module read — that
 * one is captured once at first render and never updates when the live prices arrive, so
 * a token stays pinned to the fixture (e.g. AAVE $105) even after the oracle refreshes.
 * The fixture fallback keeps SSR and the first client paint identical (no hydration
 * mismatch) and always resolves a known token to a price rather than its bare symbol.
 */
export function useCanonicalPriceFor(): (symbol: string) => number | undefined {
  const live = usePriceFor()
  return React.useCallback((symbol: string) => live(symbol) ?? PRICE_FIXTURE[symbol.trim().toUpperCase()], [live])
}

/** Freshness of the oracle prices — read this to show a "prices may be stale" indicator. */
export function usePriceFreshness(): PriceFreshness {
  const status = React.useContext(PriceStatusContext)
  const [now, setNow] = React.useState<number | null>(null)
  React.useEffect(() => {
    if (status === undefined) return undefined
    const tick = () => {
      if (document.visibilityState === "visible") setNow(Date.now())
    }
    tick()
    const id = window.setInterval(tick, 60_000)
    document.addEventListener("visibilitychange", tick)
    return () => {
      window.clearInterval(id)
      document.removeEventListener("visibilitychange", tick)
    }
  }, [status])

  if (status === undefined) return { stale: false, updatedAt: null, ageMs: null }
  if (status.updatedAt == null) return { stale: true, updatedAt: null, ageMs: null }
  if (now == null) return { stale: false, updatedAt: status.updatedAt, ageMs: null }
  const ageMs = Math.max(0, now - status.updatedAt)
  return {
    stale: ageMs > status.staleAfterMs,
    updatedAt: status.updatedAt,
    ageMs,
  }
}

/**
 * Prices are decorative — a label under the pair logos plus a "may be stale" hint — so a
 * failing Convex prices query must never take down the whole app. `useQuery` re-throws
 * server errors during render (e.g. `getPriceStatus` missing on a stale Convex deploy, or
 * the backend offline), and this provider sits ABOVE the onboarding gate in the root
 * layout, so an uncaught throw here escalates to the global error boundary ("Something
 * went wrong"). Catch it and fall back to the neutral defaults instead — cells show their
 * static labels, no staleness banner. Mirrors `MarketLiquidityErrorBoundary`.
 */
const EMPTY_PRICES: Record<string, number> = {}

/**
 * Client bridge for live tokenized-stock prices. Fetches them (currency-style, Convex-independent),
 * overlays them on the module canonical store for the engine (via setStockPrices inside
 * fetchStockPrices), and merges them into the reactive TokenPricesContext for the list/detail cells.
 * Reads the PARENT context so it composes on top of whatever map is already provided (the server
 * seed, or the Convex realtime map). Skips the network under the Lighthouse audit for determinism.
 */
function StockPriceOverlay({ children }: { children: React.ReactNode }) {
  const parent = React.useContext(TokenPricesContext)
  const [overlay, setOverlay] = React.useState<Record<string, number>>(() => stockPriceMap())
  React.useEffect(() => {
    if (isLighthouseAuditMode()) return
    const sync = () => setOverlay(stockPriceMap())
    window.addEventListener(STOCK_PRICES_UPDATED_EVENT, sync)
    // Cached quotes first (instant), then a refresh; both dispatch the event → sync.
    applyCachedStockPrices()
    void fetchStockPrices()
    // Only poll while the tab is visible — a backgrounded tab shouldn't keep hitting the network —
    // and refresh once on return so a long-hidden tab isn't left stale.
    const refreshIfVisible = () => {
      if (document.visibilityState === "visible") void fetchStockPrices()
    }
    const id = window.setInterval(refreshIfVisible, STOCK_PRICE_REFRESH_MS)
    document.addEventListener("visibilitychange", refreshIfVisible)
    sync()
    return () => {
      window.clearInterval(id)
      window.removeEventListener(STOCK_PRICES_UPDATED_EVENT, sync)
      document.removeEventListener("visibilitychange", refreshIfVisible)
    }
  }, [])
  const merged = React.useMemo(
    () => (Object.keys(overlay).length === 0 ? parent : { ...parent, ...overlay }),
    [parent, overlay],
  )
  return <TokenPricesContext.Provider value={merged}>{children}</TokenPricesContext.Provider>
}

export function TokenPricesProvider({
  children,
  initialPrices,
  realtime = true,
}: {
  children: React.ReactNode
  initialPrices?: Record<string, number>
  realtime?: boolean
}) {
  // Base context = the server-seeded live oracle prices (fetched once during SSR, keys in
  // `priceKey` form). This is what makes CLIENT-rendered prices live even though the realtime
  // Convex subscription only mounts on authenticated product routes — the client no longer
  // depends on that subscription to escape the fixture. Token prices are PUBLIC data.
  const seed = initialPrices ?? EMPTY_PRICES

  // Skip the realtime subscription when there's no Convex client (nothing to query) and under the
  // Lighthouse audit (deterministic static catalog). Open-gate sessions DO subscribe: otherwise the
  // dashboard's client price context froze at the initial-load seed while detail pages re-SSR'd
  // fresh, so the SAME token showed two prices (e.g. AAVE $123.25 on the wallet card vs $123.33 on
  // the lend detail). The subscription also calls setCanonicalPrices, so the module store the
  // detail pages / Lend / Borrow / Multiply tabs read stays in lockstep with the wallet card.
  if (!realtime || !hasConvexClient || isLighthouseAuditMode()) {
    // Guests / no-Convex / audit never render stock cells (product routes are wallet-gated), so
    // skip the stock-price overlay entirely — no unused fetch or polling timer on the guest path.
    return <TokenPricesContext.Provider value={seed}>{children}</TokenPricesContext.Provider>
  }
  return <RealtimeTokenPrices seed={seed}>{children}</RealtimeTokenPrices>
}

/**
 * The page renders here once, at a stable position. The lazy Convex subscriber is a SIBLING
 * behind `<Suspense fallback={null}>` that publishes prices up through state. It used to wrap
 * the page with `<Suspense fallback={children}>`, which made SSR stream the whole page twice
 * (fallback copy + hidden resolved copy — two <main> elements, ~2x HTML) and remounted the page
 * subtree when the chunk loaded.
 */
function RealtimeTokenPrices({ seed, children }: { seed: Record<string, number>; children: React.ReactNode }) {
  const [live, setLive] = React.useState<LivePrices | null>(null)
  const publish = React.useCallback((next: LivePrices) => {
    setLive((current) => (current && current.map === next.map && current.status === next.status ? current : next))
  }, [])
  return (
    <TokenPricesContext.Provider value={live?.map ?? seed}>
      <PriceStatusContext.Provider value={live?.status}>
        <StockPriceOverlay>{children}</StockPriceOverlay>
      </PriceStatusContext.Provider>
      <React.Suspense fallback={null}>
        <ConvexTokenPricesSubscriber seed={seed} onChange={publish} />
      </React.Suspense>
    </TokenPricesContext.Provider>
  )
}
