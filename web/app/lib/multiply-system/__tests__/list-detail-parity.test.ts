import { describe, expect, it } from "vitest"
import { buildMockMultiplySystemState } from "@/app/lib/multiply-system/mock"
import { mergeConvexMultiplySnapshots, type MultiplyConvexSnapshot } from "@/app/lib/multiply-system/market-hydration"

/**
 * List ↔ detail parity for multiply. After a Convex snapshot feeds a multiply
 * market, the hydrated market state must carry the exact snapshot values —
 * list rows read from `economics.availableLiquidityUsd / supplyApy / borrowApy`
 * and `risk.collateralFactor`, detail reads from the same fields. Any drift
 * here is a list-vs-detail divergence.
 */
describe("multiply list ↔ detail field parity after Convex hydration", () => {
  const state = buildMockMultiplySystemState()
  const firstMarket = Object.values(state.markets)[0]

  const snap: MultiplyConvexSnapshot = {
    slug: firstMarket.id,
    scope: "multiply",
    name: `${firstMarket.collateralAsset.symbol} / ${firstMarket.borrowAsset.symbol}`,
    symbol: firstMarket.collateralAsset.symbol,
    maxLtvPct: 82,
    reserveFactorPct: 12,
    suppliedUsd: 15_000_000,
    borrowedUsd: 6_000_000,
    availableUsd: 9_000_000,
    utilizationPct: 40,
    supplyApyPct: 3.7,
    borrowAprPct: 5.2,
  }

  const hydrated = mergeConvexMultiplySnapshots(state, [snap])
  const hydratedMarket = hydrated.markets[firstMarket.id]

  it("availableLiquidityUsd matches the snapshot", () => {
    expect(hydratedMarket.economics.availableLiquidityUsd).toBe(snap.availableUsd)
  })

  it("supplyApy matches the snapshot", () => {
    expect(hydratedMarket.economics.supplyApy).toBeCloseTo(snap.supplyApyPct / 100, 4)
  })

  it("borrowApy matches the snapshot borrowAprPct", () => {
    expect(hydratedMarket.economics.borrowApy).toBeCloseTo(snap.borrowAprPct / 100, 4)
  })

  it("risk.collateralFactor matches the snapshot maxLtvPct", () => {
    expect(hydratedMarket.risk.collateralFactor).toBeCloseTo(snap.maxLtvPct! / 100, 4)
  })

  it("economics.reserveFactorPct matches the snapshot", () => {
    expect(hydratedMarket.economics.reserveFactorPct).toBe(snap.reserveFactorPct)
  })

  it("silent field fallback preserves the previous value on partial re-hydration", () => {
    const partial: MultiplyConvexSnapshot = { ...snap, reserveFactorPct: undefined, maxLtvPct: undefined }
    const re = mergeConvexMultiplySnapshots(hydrated, [partial])
    expect(re.markets[firstMarket.id].economics.reserveFactorPct).toBe(snap.reserveFactorPct)
    expect(re.markets[firstMarket.id].risk.collateralFactor).toBeCloseTo(snap.maxLtvPct! / 100, 4)
  })
})
