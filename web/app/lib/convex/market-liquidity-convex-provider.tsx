"use client"

import { Component, useMemo, type ReactNode } from "react"
import { useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"
import {
  MarketLiquidityContext,
  type MarketLiquidityDelta,
  type MarketLiquidityValue,
  type RecordDeltaInput,
} from "./market-liquidity-provider"
import { getSiweConvexClient, SiweConvexProvider } from "./siwe-convex-provider"

function MarketLiquidityBridge({
  localDeltas,
  recordLocal,
  children,
}: {
  localDeltas: Map<string, MarketLiquidityDelta>
  recordLocal: (input: RecordDeltaInput) => void
  children: ReactNode
}) {
  const rows = useQuery(api.liquidity.listDeltaSnapshot)
  const connected = rows !== undefined
  const value = useMemo<MarketLiquidityValue>(() => {
    if (!connected)
      return {
        deltas: localDeltas,
        connected: false,
        recordDelta: recordLocal,
      }
    const deltas = new Map<string, MarketLiquidityDelta>()
    for (const row of rows ?? []) {
      deltas.set(row.marketSlug, {
        borrowedDeltaUsd: row.borrowedDeltaUsd,
        suppliedDeltaUsd: row.suppliedDeltaUsd,
      })
    }
    return { deltas, connected: true, recordDelta: () => undefined }
  }, [connected, localDeltas, recordLocal, rows])
  return <MarketLiquidityContext.Provider value={value}>{children}</MarketLiquidityContext.Provider>
}

class MarketLiquidityErrorBoundary extends Component<
  {
    children: ReactNode
    fallbackChildren: ReactNode
    fallbackValue: MarketLiquidityValue
  },
  { errored: boolean }
> {
  state = { errored: false }
  static getDerivedStateFromError() {
    return { errored: true }
  }
  render() {
    if (this.state.errored) {
      return (
        <MarketLiquidityContext.Provider value={this.props.fallbackValue}>
          {this.props.fallbackChildren}
        </MarketLiquidityContext.Provider>
      )
    }
    return this.props.children
  }
}

export default function ConvexMarketLiquidityProvider({
  localDeltas,
  recordLocal,
  fallbackValue,
  children,
}: {
  localDeltas: Map<string, MarketLiquidityDelta>
  recordLocal: (input: RecordDeltaInput) => void
  fallbackValue: MarketLiquidityValue
  children: ReactNode
}) {
  if (!getSiweConvexClient()) {
    return <MarketLiquidityContext.Provider value={fallbackValue}>{children}</MarketLiquidityContext.Provider>
  }
  // Reuses the gate's provider when mounted beneath it (single socket / single auth).
  return (
    <SiweConvexProvider>
      <MarketLiquidityErrorBoundary fallbackChildren={children} fallbackValue={fallbackValue}>
        <MarketLiquidityBridge localDeltas={localDeltas} recordLocal={recordLocal}>
          {children}
        </MarketLiquidityBridge>
      </MarketLiquidityErrorBoundary>
    </SiweConvexProvider>
  )
}
