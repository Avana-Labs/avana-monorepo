"use client"

import * as React from "react"
import { useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"
import { setCanonicalPrices } from "./canonical"
import { priceKey } from "./format"
import type { LivePrices } from "./token-prices-context"
import { applyLiveRates } from "@/app/lib/currency/rates"
import { FX_RATES_UPDATED_EVENT } from "@/app/lib/currency/rates"
import type { CurrencyCode } from "@/app/components/display-preferences"
import { validatedConvexPriceMap } from "./validated-convex-price"
import { registerPriceSubscription } from "./price-subscription-telemetry"

/** A failing prices query must never take the page down: the subscriber just stops publishing. */
class TokenPricesErrorBoundary extends React.Component<{ children: React.ReactNode }, { errored: boolean }> {
  state = { errored: false }
  static getDerivedStateFromError() {
    return { errored: true }
  }
  render() {
    if (this.state.errored) return null
    return this.props.children
  }
}

function samePriceMap(a: Record<string, number>, b: Record<string, number>) {
  const keys = Object.keys(a)
  if (keys.length !== Object.keys(b).length) return false
  return keys.every((key) => a[key] === b[key])
}

function ConvexTokenPricesQuery({
  seed = EMPTY_SEED,
  onChange,
}: {
  seed?: Record<string, number>
  onChange: (live: LivePrices) => void
}) {
  const snapshot = useQuery(api.prices.getPriceSnapshot, {})
  const providerStatus = useQuery(api.prices.getPriceStatus, {})
  React.useEffect(() => {
    const route = typeof window === "undefined" ? "" : window.location.pathname
    return registerPriceSubscription(route)
  }, [])
  const rows = snapshot?.prices
  // Quote map stays on getPriceSnapshot (no health read). Provider checkedAt is a separate
  // subscription so identical refreshes do not invalidate every price consumer.
  // Memoized on its fields: the object is published to the provider, and a fresh identity
  // every render would re-publish (and re-render every price consumer) in a loop.
  const statusSource = providerStatus
    ? {
        updatedAt: providerStatus.updatedAt,
        staleAfterMs: providerStatus.staleAfterMs,
        invalidAfterMs: snapshot?.status.invalidAfterMs,
        count: providerStatus.count,
      }
    : snapshot?.status
  const statusUpdatedAt = statusSource?.updatedAt
  const statusStaleAfterMs = statusSource?.staleAfterMs
  const statusInvalidAfterMs = statusSource?.invalidAfterMs
  const statusCount = statusSource?.count
  const hasStatus = statusSource !== undefined
  const status = React.useMemo(
    () =>
      hasStatus
        ? {
            updatedAt: statusUpdatedAt ?? null,
            staleAfterMs: statusStaleAfterMs as number,
            invalidAfterMs: statusInvalidAfterMs,
            count: statusCount as number,
          }
        : undefined,
    [hasStatus, statusUpdatedAt, statusStaleAfterMs, statusInvalidAfterMs, statusCount],
  )
  const [validationNow, setValidationNow] = React.useState(() => Date.now())
  React.useEffect(() => {
    if (!rows?.length) return
    const timer = window.setInterval(() => setValidationNow(Date.now()), 60_000)
    return () => window.clearInterval(timer)
  }, [rows])
  // Start from the server seed (live prices fetched during SSR) and overlay the realtime rows
  // on top when the subscription delivers them — so consumers stay live even while the query is
  // loading or when it never resolves (no realtime client on this route).
  // The 60s validation tick only matters when a quote crosses its invalid age, so keep the
  // previous map while the contents are equal; a new identity re-renders every price consumer.
  const previousMap = React.useRef<Record<string, number> | null>(null)
  const map = React.useMemo(() => {
    const next: Record<string, number> = { ...seed }
    const validated = validatedConvexPriceMap(rows ?? [], validationNow, status?.invalidAfterMs)
    for (const row of rows ?? []) {
      if (!(row.symbol.trim().toLowerCase() in validated)) delete next[priceKey(row.symbol)]
    }
    for (const [symbol, priceUsd] of Object.entries(validated)) next[priceKey(symbol)] = priceUsd
    return previousMap.current && samePriceMap(previousMap.current, next) ? previousMap.current : next
  }, [rows, seed, status?.invalidAfterMs, validationNow])
  React.useEffect(() => {
    previousMap.current = map
  }, [map])
  // Overlay the same seed+live prices onto the module canonical store so the engine + any
  // non-reactive `canonicalPriceUsd` reader also sees the refreshed price (not just the
  // fixture). Effect, not render, to avoid a side-effect during render.
  const lastCanonical = React.useRef<Record<string, number> | null>(null)
  React.useEffect(() => {
    const merged: Record<string, number> = { ...seed }
    const validated = validatedConvexPriceMap(rows ?? [], validationNow, status?.invalidAfterMs)
    for (const row of rows ?? []) {
      if (!(row.symbol.trim().toLowerCase() in validated)) {
        delete merged[priceKey(row.symbol)]
        delete merged[row.symbol]
      }
    }
    for (const [symbol, priceUsd] of Object.entries(validated)) merged[symbol] = priceUsd
    if (Object.keys(merged).length === 0) return
    if (lastCanonical.current && samePriceMap(lastCanonical.current, merged)) return
    lastCanonical.current = merged
    setCanonicalPrices(merged)
  }, [rows, seed, status?.invalidAfterMs, validationNow])

  // Fiat FX rates from the validated Convex layer (convex/fx.ts). Apply them onto the currency
  // overlay so conversion flows through Convex rather than only the client poll, then notify the
  // preferences provider to re-render currency consumers. Falls back to the /api/fx-rates client
  // path when Convex has no rows yet.
  const fx = useQuery(api.fx.getFxRates, {})
  const fxRows = fx?.rates
  React.useEffect(() => {
    if (fxRows && fxRows.length > 0) {
      applyLiveRates(
        Object.fromEntries(fxRows.map((r) => [r.currency, r.usdPerUnit])) as Partial<Record<CurrencyCode, number>>,
      )
      window.dispatchEvent(new Event(FX_RATES_UPDATED_EVENT))
    }
  }, [fxRows])

  // Publish up to TokenPricesProvider, which owns the context. This component renders
  // nothing, so the page is never nested inside (or remounted by) this lazy module.
  React.useEffect(() => {
    onChange({ map, status })
  }, [map, status, onChange])

  return null
}

const EMPTY_SEED: Record<string, number> = {}

/**
 * Realtime Convex prices, as a render-nothing sibling of the page: it subscribes and pushes
 * `{ map, status }` to `onChange`. Lazy-loaded by TokenPricesProvider behind
 * `<Suspense fallback={null}>`, so SSR renders the page once and the subscription attaching
 * later never remounts it.
 */
export default function ConvexTokenPricesSubscriber({
  seed,
  onChange,
}: {
  seed?: Record<string, number>
  onChange: (live: LivePrices) => void
}) {
  return (
    <TokenPricesErrorBoundary>
      <ConvexTokenPricesQuery seed={seed} onChange={onChange} />
    </TokenPricesErrorBoundary>
  )
}
