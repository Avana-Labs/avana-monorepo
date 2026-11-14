"use client"

import { lazy, Suspense, createContext, useCallback, useContext, useMemo, useState, type ReactNode } from "react"

export type MarketLiquidityDelta = {
  borrowedDeltaUsd: number
  suppliedDeltaUsd: number
}

export type RecordDeltaInput = {
  marketSlug: string
  borrowedDeltaUsd?: number
  suppliedDeltaUsd?: number
}

export type MarketLiquidityValue = {
  /**
   * Per-slug aggregate liquidity deltas layered on the static catalog base.
   * Keying convention (single source of truth for every surface):
   *   - borrowable-asset liquidity → keyed by ASSET id  (borrowedDeltaUsd)
   *   - pool / market supplied TVL  → keyed by MARKET id (suppliedDeltaUsd)
   * Use the helpers in `@/app/lib/market-liquidity/apply` rather than reading raw.
   */
  deltas: Map<string, MarketLiquidityDelta>
  /** True once the shared Convex ledger query has resolved (cross-user mode). */
  connected: boolean
  /** Fold a borrow/repay/supply/withdraw into the ledger (Convex when online, else local). */
  recordDelta: (input: RecordDeltaInput) => void
}

const EMPTY_DELTAS = new Map<string, MarketLiquidityDelta>()

export const MarketLiquidityContext = createContext<MarketLiquidityValue>({
  deltas: EMPTY_DELTAS,
  connected: false,
  recordDelta: () => undefined,
})

const convexUrl = process.env.NEXT_PUBLIC_CONVEX_URL
export const hasConvexClient = Boolean(convexUrl && /^https?:\/\//.test(convexUrl))
const ConvexMarketLiquidityProvider = lazy(() => import("./market-liquidity-convex-provider"))

function mergeDelta(map: Map<string, MarketLiquidityDelta>, input: RecordDeltaInput) {
  const borrowedDeltaUsd = Number.isFinite(input.borrowedDeltaUsd) ? (input.borrowedDeltaUsd as number) : 0
  const suppliedDeltaUsd = Number.isFinite(input.suppliedDeltaUsd) ? (input.suppliedDeltaUsd as number) : 0
  if (borrowedDeltaUsd === 0 && suppliedDeltaUsd === 0) return map
  const next = new Map(map)
  const current = next.get(input.marketSlug) ?? {
    borrowedDeltaUsd: 0,
    suppliedDeltaUsd: 0,
  }
  next.set(input.marketSlug, {
    borrowedDeltaUsd: current.borrowedDeltaUsd + borrowedDeltaUsd,
    suppliedDeltaUsd: current.suppliedDeltaUsd + suppliedDeltaUsd,
  })
  return next
}

/**
 * Client-local fallback ledger. Whenever the shared Convex ledger is unreachable
 * (no `NEXT_PUBLIC_CONVEX_URL`, or configured but offline), the wallet's own
 * borrow/lend/supply/withdraw still move market liquidity in-session so every
 * surface stays stateful and consistent. When Convex connects, its cross-user
 * deltas take over and this local store is ignored.
 */
function useLocalLedger() {
  const [localDeltas, setLocalDeltas] = useState<Map<string, MarketLiquidityDelta>>(EMPTY_DELTAS)
  const recordLocal = useCallback((input: RecordDeltaInput) => {
    setLocalDeltas((current) => mergeDelta(current, input))
  }, [])
  return { localDeltas, recordLocal }
}

export function MarketLiquidityProvider({ children, live = false }: { children: ReactNode; live?: boolean }) {
  const { localDeltas, recordLocal } = useLocalLedger()
  const fallbackValue = useMemo(
    () => ({ deltas: localDeltas, connected: false, recordDelta: recordLocal }),
    [localDeltas, recordLocal],
  )
  const localTree = <MarketLiquidityContext.Provider value={fallbackValue}>{children}</MarketLiquidityContext.Provider>

  if (!live || !hasConvexClient) return localTree
  return (
    <Suspense fallback={localTree}>
      <ConvexMarketLiquidityProvider localDeltas={localDeltas} recordLocal={recordLocal} fallbackValue={fallbackValue}>
        {children}
      </ConvexMarketLiquidityProvider>
    </Suspense>
  )
}

/** Live shared-ledger deltas + recorder. Falls back to the in-session local ledger when Convex is absent. */
export function useMarketLiquidity() {
  return useContext(MarketLiquidityContext)
}

/**
 * True when a Convex client is configured (NEXT_PUBLIC_CONVEX_URL set). Stable for
 * the session (decided at module load). Use it to conditionally RENDER components
 * that call Convex's `useQuery` so they only mount when a ConvexProvider exists.
 */
