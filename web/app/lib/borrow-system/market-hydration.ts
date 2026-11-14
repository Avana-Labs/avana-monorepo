import { parseFixed, type BorrowSystemState } from "@/app/lib/credit-engine"
import { warnLiveFallback } from "@/app/lib/data/providers/hydration-telemetry"

/** One row from convex/markets.ts `listMarketSnapshots`. */
export type ConvexMarketSnapshot = {
  slug: string
  scope: "asset" | "pool"
  name?: string
  symbol?: string
  maxLtvPct?: number
  premiumBps?: number
  reserveFactorPct?: number
  suppliedUsd: number
  borrowedUsd: number
  availableUsd: number
  utilizationPct: number
  supplyApyPct: number
  borrowAprPct: number
  tvlUsd: number
  volumeUsd: number
  feesUsd: number
  /** Pools: the live LP unit price the server values pledged LP tokens at. */
  lpPriceUsd?: number
}

function usd6(value: number) {
  return parseFixed(Math.max(0, value).toFixed(6), 6)
}

function wadFromPct(pct: number) {
  return parseFixed((Math.max(0, pct) / 100).toFixed(18), 18)
}

/**
 * Fold Convex market reference data into a borrow system state so the session
 * (list, previews, health factor) reads the SAME numbers as the hero/detail.
 * Overwrites market-level liquidity/rate fields plus list identity/LTV/premium when
 * present on the snapshot. Returns the SAME state reference when nothing changed.
 */
export function mergeConvexMarketSnapshots(
  state: BorrowSystemState,
  snapshots: readonly ConvexMarketSnapshot[],
): BorrowSystemState {
  if (snapshots.length === 0) return state
  let changed = false
  const markets = { ...state.markets }
  const assets = { ...state.assets }

  for (const snap of snapshots) {
    if (snap.scope === "pool") {
      const market = markets[snap.slug]
      if (!market) continue
      const nextSnapshot = {
        ...market.snapshot,
        totalLiquidityUsd6: usd6(snap.tvlUsd),
        totalBorrowedUsd6: usd6(snap.borrowedUsd),
        availableUsd6: usd6(snap.availableUsd),
        volume24hUsd6: usd6(snap.volumeUsd),
        fees24hUsd6: usd6(snap.feesUsd),
        feeApyWad: wadFromPct(snap.supplyApyPct),
        // The server's live LP price; the catalog price is a build-time estimate.
        lpTokenPriceUsd6:
          snap.lpPriceUsd !== undefined && Number.isFinite(snap.lpPriceUsd) && snap.lpPriceUsd > 0
            ? usd6(snap.lpPriceUsd)
            : market.snapshot.lpTokenPriceUsd6,
      }
      let nextCf: bigint
      if (snap.maxLtvPct !== undefined && Number.isFinite(snap.maxLtvPct)) {
        nextCf = wadFromPct(snap.maxLtvPct)
      } else {
        warnLiveFallback("borrow", snap.slug, "maxLtvPct")
        nextCf = market.riskConfig.collateralFactorWad
      }
      let nextName: string
      if (snap.name?.trim()) {
        nextName = snap.name
      } else {
        warnLiveFallback("borrow", snap.slug, "name")
        nextName = market.display.name
      }
      const nextPremium = snap.premiumBps
      let nextReserveFactorPct: number | undefined
      if (snap.reserveFactorPct !== undefined && Number.isFinite(snap.reserveFactorPct)) {
        nextReserveFactorPct = snap.reserveFactorPct
      } else {
        warnLiveFallback("borrow", snap.slug, "reserveFactorPct")
        nextReserveFactorPct = market.reserveFactorPct
      }
      const s = market.snapshot
      if (
        s.totalLiquidityUsd6 === nextSnapshot.totalLiquidityUsd6 &&
        s.totalBorrowedUsd6 === nextSnapshot.totalBorrowedUsd6 &&
        s.availableUsd6 === nextSnapshot.availableUsd6 &&
        s.volume24hUsd6 === nextSnapshot.volume24hUsd6 &&
        s.fees24hUsd6 === nextSnapshot.fees24hUsd6 &&
        s.feeApyWad === nextSnapshot.feeApyWad &&
        s.lpTokenPriceUsd6 === nextSnapshot.lpTokenPriceUsd6 &&
        market.riskConfig.collateralFactorWad === nextCf &&
        market.display.name === nextName &&
        market.listPremiumBps === nextPremium &&
        market.reserveFactorPct === nextReserveFactorPct
      ) {
        continue
      }
      markets[snap.slug] = {
        ...market,
        display: { ...market.display, name: nextName },
        riskConfig: { ...market.riskConfig, collateralFactorWad: nextCf },
        listPremiumBps: nextPremium,
        reserveFactorPct: nextReserveFactorPct,
        snapshot: nextSnapshot,
      }
      changed = true
    } else {
      const asset = assets[snap.slug]
      if (!asset) continue
      const availableLiquidityUsd6 = usd6(snap.availableUsd)
      const totalBorrowedUsd6 = usd6(snap.borrowedUsd)
      const baseBorrowAprWad = wadFromPct(snap.borrowAprPct)
      let nextName: string
      if (snap.name?.trim()) {
        nextName = snap.name
      } else {
        warnLiveFallback("borrow", snap.slug, "name")
        nextName = asset.display.name
      }
      let nextSymbol: string
      if (snap.symbol?.trim()) {
        nextSymbol = snap.symbol
      } else {
        warnLiveFallback("borrow", snap.slug, "symbol")
        nextSymbol = asset.symbol
      }
      let nextReserveFactorPct: number | undefined
      if (snap.reserveFactorPct !== undefined && Number.isFinite(snap.reserveFactorPct)) {
        nextReserveFactorPct = snap.reserveFactorPct
      } else {
        warnLiveFallback("borrow", snap.slug, "reserveFactorPct")
        nextReserveFactorPct = asset.reserveFactorPct
      }
      const a = asset.snapshot
      if (
        asset.borrowConfig.baseBorrowAprWad === baseBorrowAprWad &&
        a.availableLiquidityUsd6 === availableLiquidityUsd6 &&
        a.totalBorrowedUsd6 === totalBorrowedUsd6 &&
        a.totalDebtSharesUsd6 === totalBorrowedUsd6 &&
        asset.display.name === nextName &&
        asset.symbol === nextSymbol &&
        asset.reserveFactorPct === nextReserveFactorPct
      ) {
        continue
      }
      assets[snap.slug] = {
        ...asset,
        symbol: nextSymbol,
        display: { ...asset.display, name: nextName },
        borrowConfig: { ...asset.borrowConfig, baseBorrowAprWad },
        reserveFactorPct: nextReserveFactorPct,
        snapshot: {
          ...asset.snapshot,
          availableLiquidityUsd6,
          totalBorrowedUsd6,
          totalDebtSharesUsd6: totalBorrowedUsd6,
        },
      }
      changed = true
    }
  }

  return changed ? { ...state, markets, assets } : state
}
