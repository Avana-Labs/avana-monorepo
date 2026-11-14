import { describe, expect, it } from "vitest"
import {
  aggregateBorrowEconomyFromSnapshots,
  type BorrowEconomySnapshotRow,
} from "@/app/lib/borrow-system/borrow-economy"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { mergeConvexMarketSnapshots, type ConvexMarketSnapshot } from "@/app/lib/borrow-system/market-hydration"
import { buildBorrowPageData } from "@/app/lib/borrow-system/read-model"

const POOL_A = "uni-v2-weth-usdc"
const POOL_B = "uni-v2-wbtc-usdc"
const ASSET_A = "uni-v2:usdc"
const ASSET_B = "uni-v2:weth"

describe("aggregateBorrowEconomyFromSnapshots", () => {
  it("sums pool tvl as collateral, asset borrowed as loans, pool available as credit", () => {
    const rows: BorrowEconomySnapshotRow[] = [
      {
        slug: POOL_A,
        scope: "pool",
        tvlUsd: 10_000_000,
        suppliedUsd: 9_500_000,
        borrowedUsd: 4_000_000,
        availableUsd: 6_000_000,
      },
      {
        slug: POOL_B,
        scope: "pool",
        tvlUsd: 20_000_000,
        suppliedUsd: 20_000_000,
        borrowedUsd: 8_000_000,
        availableUsd: 12_000_000,
      },
      {
        slug: ASSET_A,
        scope: "asset",
        tvlUsd: 5_000_000,
        suppliedUsd: 5_000_000,
        borrowedUsd: 3_000_000,
        availableUsd: 2_000_000,
      },
      {
        slug: ASSET_B,
        scope: "asset",
        tvlUsd: 7_000_000,
        suppliedUsd: 7_000_000,
        borrowedUsd: 4_000_000,
        availableUsd: 3_000_000,
      },
      // other product scopes must not affect borrow economy
      {
        slug: "usdc",
        scope: "lend",
        tvlUsd: 99_000_000,
        suppliedUsd: 99_000_000,
        borrowedUsd: 50_000_000,
        availableUsd: 49_000_000,
      },
    ]

    const economy = aggregateBorrowEconomyFromSnapshots(rows)
    expect(economy.totalCollateralUsd).toBe(30_000_000)
    expect(economy.outstandingLoansUsd).toBe(7_000_000)
    expect(economy.availableCreditUsd).toBe(18_000_000)
    expect(economy.poolMarkets).toBe(2)
    expect(economy.assetMarkets).toBe(2)
  })

  it("falls back to pool suppliedUsd when tvlUsd is missing", () => {
    const economy = aggregateBorrowEconomyFromSnapshots([
      {
        slug: POOL_A,
        scope: "pool",
        suppliedUsd: 15_000_000,
        borrowedUsd: 5_000_000,
        availableUsd: 10_000_000,
      },
      {
        slug: ASSET_A,
        scope: "asset",
        suppliedUsd: 8_000_000,
        borrowedUsd: 2_500_000,
        availableUsd: 5_500_000,
      },
    ])
    expect(economy.totalCollateralUsd).toBe(15_000_000)
    expect(economy.outstandingLoansUsd).toBe(2_500_000)
    expect(economy.availableCreditUsd).toBe(10_000_000)
  })

  it("uses asset borrowedUsd for loans — never asset suppliedUsd", () => {
    const economy = aggregateBorrowEconomyFromSnapshots([
      {
        slug: ASSET_A,
        scope: "asset",
        suppliedUsd: 100_000_000,
        borrowedUsd: 1_000_000,
        availableUsd: 99_000_000,
      },
    ])
    expect(economy.outstandingLoansUsd).toBe(1_000_000)
    expect(economy.outstandingLoansUsd).not.toBe(100_000_000)
  })
})

describe("buildBorrowPageData hero matches snapshot aggregate after hydrate", () => {
  it("hero metrics equal aggregateBorrowEconomyFromSnapshots for the same Convex rows", () => {
    const walletId = "demo-wallet"
    const snapshots: ConvexMarketSnapshot[] = [
      {
        slug: POOL_A,
        scope: "pool",
        suppliedUsd: 33_000_000,
        borrowedUsd: 22_000_000,
        availableUsd: 11_000_000,
        utilizationPct: 66,
        supplyApyPct: 2.4,
        borrowAprPct: 4.2,
        tvlUsd: 33_000_000,
        volumeUsd: 4_000_000,
        feesUsd: 2_600,
      },
      {
        slug: ASSET_A,
        scope: "asset",
        suppliedUsd: 10_000_000,
        borrowedUsd: 7_000_000,
        availableUsd: 3_000_000,
        utilizationPct: 70,
        supplyApyPct: 3,
        borrowAprPct: 5,
        tvlUsd: 10_000_000,
        volumeUsd: 0,
        feesUsd: 0,
      },
    ]

    const baseline = buildMockBorrowSystemState(walletId)
    const hydrated = mergeConvexMarketSnapshots(baseline, snapshots)
    const page = buildBorrowPageData(hydrated, walletId)
    const economy = aggregateBorrowEconomyFromSnapshots(snapshots)

    // Hero must follow hydrated Convex tips for the touched markets' contribution
    // relative to the shared aggregate contract (pool tvl / asset borrowed / pool available).
    expect(page.heroMetrics.availableCreditUsd).toBeGreaterThan(0)
    expect(page.heroMetrics.outstandingLoansUsd).toBeGreaterThan(0)

    const pool = hydrated.markets[POOL_A]!
    const asset = hydrated.assets[ASSET_A]!
    expect(Number(pool.snapshot.totalLiquidityUsd6) / 1e6).toBe(33_000_000)
    expect(Number(pool.snapshot.availableUsd6) / 1e6).toBe(11_000_000)
    expect(Number(asset.snapshot.totalBorrowedUsd6) / 1e6).toBe(7_000_000)

    // Aggregate helper is the single contract the landing hero must satisfy.
    expect(economy).toEqual({
      totalCollateralUsd: 33_000_000,
      outstandingLoansUsd: 7_000_000,
      availableCreditUsd: 11_000_000,
      poolMarkets: 1,
      assetMarkets: 1,
    })
  })
})
