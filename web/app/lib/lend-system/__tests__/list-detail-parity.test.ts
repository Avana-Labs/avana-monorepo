import { describe, expect, it } from "vitest"
import { buildMockLendSystemState } from "@/app/lib/lend-system/mock"
import { mergeConvexLendSnapshots, type LendConvexSnapshot } from "@/app/lib/lend-system/market-hydration"

/**
 * List ↔ detail parity for lend. After a Convex snapshot feeds a lend market,
 * the hydrated market state must carry the exact snapshot values — both the
 * list row and the detail's headline stats read from this state, so any drift
 * here is a list-vs-detail divergence.
 */
describe("lend list ↔ detail field parity after Convex hydration", () => {
  const state = buildMockLendSystemState()
  const firstMarket = Object.values(state.markets)[0]

  const snap: LendConvexSnapshot = {
    slug: firstMarket.marketId,
    scope: "lend",
    name: firstMarket.asset.name,
    symbol: firstMarket.asset.symbol,
    suppliedUsd: 200_000_000,
    borrowedUsd: 120_000_000,
    availableUsd: 80_000_000,
    utilizationPct: 60,
    supplyApyPct: 4.2,
    reserveFactorPct: 15,
    rewardsApyPct: 0.75,
    assetPriceUsd: 1.01,
    priceUpdatedAt: 1_777_777_777_777,
  }

  const hydrated = mergeConvexLendSnapshots(state, [snap])
  const hydratedMarket = hydrated.markets[firstMarket.marketId]
  const price = hydratedMarket.assetPriceUsd || 1

  it("supplied matches the snapshot", () => {
    expect(hydratedMarket.totalSupplied * price).toBeCloseTo(snap.suppliedUsd, 0)
  })

  it("borrowed matches the snapshot", () => {
    expect(hydratedMarket.totalBorrowed * price).toBeCloseTo(snap.borrowedUsd, 0)
  })

  it("availableLiquidity matches the snapshot", () => {
    expect(hydratedMarket.availableLiquidity * price).toBeCloseTo(snap.availableUsd, 0)
  })

  it("utilization matches the snapshot", () => {
    expect(hydratedMarket.utilization).toBeCloseTo(snap.utilizationPct / 100, 4)
  })

  it("supplyApy matches the snapshot", () => {
    expect(hydratedMarket.supplyApy).toBeCloseTo(snap.supplyApyPct / 100, 4)
  })

  it("reserveFactor matches the snapshot", () => {
    expect(hydratedMarket.reserveFactor).toBeCloseTo(snap.reserveFactorPct! / 100, 4)
  })

  it("rewardsApy matches the snapshot", () => {
    expect(hydratedMarket.rewardsApy).toBeCloseTo(snap.rewardsApyPct! / 100, 4)
  })

  it("engine valuation and freshness use the same Convex quote as the UI", () => {
    expect(hydratedMarket.assetPriceUsd).toBe(snap.assetPriceUsd)
    expect(hydratedMarket.asset.priceUsd).toBe(snap.assetPriceUsd)
    expect(hydratedMarket.priceUpdatedAt).toBe(snap.priceUpdatedAt)
  })

  it("silent field fallback preserves the previous value when a re-hydration omits it", () => {
    const partial: LendConvexSnapshot = { ...snap, reserveFactorPct: undefined }
    const re = mergeConvexLendSnapshots(hydrated, [partial])
    expect(re.markets[firstMarket.marketId].reserveFactor).toBeCloseTo(snap.reserveFactorPct! / 100, 4)
  })
})
