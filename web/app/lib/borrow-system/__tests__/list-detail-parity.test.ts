import { describe, expect, it } from "vitest"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { mergeConvexMarketSnapshots, type ConvexMarketSnapshot } from "@/app/lib/borrow-system/market-hydration"
import { selectBorrowMarketSummaries, selectBorrowableAssets } from "@/app/lib/borrow-system/selectors"

/**
 * List ↔ detail parity across hydration. After the same Convex snapshot batch
 * feeds a market state, the list row and the detail's QuickStats-adjacent
 * numbers must read the SAME value for every reference field. Regression trap:
 * any future edit that silently drops a snapshot field on one path (either
 * the list selector or the detail overlay) trips this test.
 */
describe("borrow list ↔ detail field parity after Convex hydration", () => {
  const walletId = "0x0000000000000000000000000000000000000a11"
  const base = buildMockBorrowSystemState(walletId)
  const firstMarket = Object.values(base.markets)[0]
  const firstAsset = Object.values(base.assets)[0]

  const poolSnap: ConvexMarketSnapshot = {
    slug: firstMarket.id,
    scope: "pool",
    name: "Test Pool",
    suppliedUsd: 42_000_000,
    borrowedUsd: 20_000_000,
    availableUsd: 22_000_000,
    utilizationPct: 47.62,
    supplyApyPct: 3.14,
    borrowAprPct: 5.28,
    tvlUsd: 42_000_000,
    volumeUsd: 1_200_000,
    feesUsd: 4_500,
    maxLtvPct: 65,
    premiumBps: 86,
    reserveFactorPct: 12,
  }
  const assetSnap: ConvexMarketSnapshot = {
    slug: firstAsset.id,
    scope: "asset",
    name: firstAsset.display.name,
    symbol: firstAsset.symbol,
    suppliedUsd: 55_000_000,
    borrowedUsd: 30_000_000,
    availableUsd: 25_000_000,
    utilizationPct: 54.55,
    supplyApyPct: 2.71,
    borrowAprPct: 4.19,
    tvlUsd: 55_000_000,
    volumeUsd: 0,
    feesUsd: 0,
    reserveFactorPct: 10,
  }

  const hydrated = mergeConvexMarketSnapshots(base, [poolSnap, assetSnap])
  const listPools = selectBorrowMarketSummaries(hydrated, walletId)
  const listAssets = selectBorrowableAssets(hydrated, walletId)

  const poolRow = listPools.find((row) => row.id === firstMarket.id)
  const assetRow = listAssets.find((row) => row.id === firstAsset.id)
  const hydratedPool = hydrated.markets[firstMarket.id]
  const hydratedAsset = hydrated.assets[firstAsset.id]

  it("pool tvlUsd matches the snapshot on both list row and hydrated state", () => {
    expect(poolRow?.tvlUsd).toBe(poolSnap.tvlUsd)
    expect(Number(hydratedPool.snapshot.totalLiquidityUsd6) / 1e6).toBe(poolSnap.tvlUsd)
  })

  it("pool availableUsd matches on both surfaces", () => {
    expect(poolRow?.availableUsd).toBe(poolSnap.availableUsd)
    expect(Number(hydratedPool.snapshot.availableUsd6) / 1e6).toBe(poolSnap.availableUsd)
  })

  it("pool capacity filled matches the detail utilization from borrowed over supplied", () => {
    expect(poolRow?.capacityFilledPct).toBeCloseTo(poolSnap.utilizationPct, 2)
  })

  it("pool reserveFactorPct is stored on hydrated market for the detail overlay", () => {
    expect(hydratedPool.reserveFactorPct).toBe(poolSnap.reserveFactorPct)
  })

  it("pool premiumBps stored on hydrated market for the list surface", () => {
    expect(hydratedPool.listPremiumBps).toBe(poolSnap.premiumBps)
  })

  it("asset borrowedUsd matches on both surfaces", () => {
    expect(assetRow?.totalBorrowedUsd).toBe(assetSnap.borrowedUsd)
    expect(Number(hydratedAsset.snapshot.totalBorrowedUsd6) / 1e6).toBe(assetSnap.borrowedUsd)
  })

  it("asset reserveFactorPct is stored on hydrated asset for the detail overlay", () => {
    expect(hydratedAsset.reserveFactorPct).toBe(assetSnap.reserveFactorPct)
  })

  it("silent field fallback does NOT overwrite the previous value when snapshot omits it", () => {
    // Second-round hydration with a snapshot missing reserveFactorPct — the previously
    // stored value must survive rather than reset to catalog default.
    const partialSnap: ConvexMarketSnapshot = { ...poolSnap, reserveFactorPct: undefined }
    const re = mergeConvexMarketSnapshots(hydrated, [partialSnap])
    expect(re.markets[firstMarket.id].reserveFactorPct).toBe(poolSnap.reserveFactorPct)
  })
})
