"use client"

/**
 * Public market-reference hydrate only (no wallet / swap / rewards queries).
 * Used by DEV_OPEN_GATE where SIWE is skipped but list/detail must still share
 * Convex snapshot TVLs instead of catalog ~$99M figures.
 *
 * Prices come from TokenPricesContext (the shared oracle subscription) —
 * this module must NOT open a second prices query.
 */
import { useContext, useEffect } from "react"
import { useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"
import type { ConvexMarketSnapshot } from "@/app/lib/borrow-system/market-hydration"
import type { LendConvexSnapshot } from "@/app/lib/lend-system/market-hydration"
import { PriceStatusContext, usePriceFor } from "@/app/lib/prices/token-prices-context"
import { useBorrowSessionContext, useLendSessionContext } from "./avana-sessions-provider"
import type { ProductRuntimeScope } from "./product-runtime-scope"

export function ConvexMarketSnapshotHydrators({ scope }: { scope: ProductRuntimeScope }) {
  const borrow = useBorrowSessionContext()
  const lend = useLendSessionContext()
  const priceFor = usePriceFor()
  const priceStatus = useContext(PriceStatusContext)
  // One reactive subscription for all products instead of one per product. The rows carry
  // `scope`, so we partition client-side. Skipped on routes that do not need catalogs.
  const snapshots = useQuery(api.markets.listMarketSnapshots, scope.marketSnapshots ? {} : "skip")

  useEffect(() => {
    if (!scope.hydrateBorrowMarkets || !snapshots) return
    const rows = snapshots.filter((row) => row.scope === "pool" || row.scope === "asset")
    if (rows.length > 0) borrow.hydrateMarketData(rows as ConvexMarketSnapshot[])
  }, [borrow.hydrateMarketData, scope.hydrateBorrowMarkets, snapshots])

  useEffect(() => {
    if (!scope.hydrateLendMarkets || !snapshots) return
    const rows = snapshots
      .filter((row) => row.scope === "lend")
      .map((row) => {
        const assetPriceUsd = priceFor(row.symbol)
        return assetPriceUsd != null
          ? { ...row, assetPriceUsd, priceUpdatedAt: priceStatus?.updatedAt ?? undefined }
          : row
      })
    if (rows.length > 0) lend.hydrateMarketData(rows as LendConvexSnapshot[])
  }, [lend.hydrateMarketData, priceFor, priceStatus?.updatedAt, scope.hydrateLendMarkets, snapshots])

  return null
}
