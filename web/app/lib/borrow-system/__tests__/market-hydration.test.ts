import { describe, expect, it } from "vitest"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { mergeConvexMarketSnapshots, type ConvexMarketSnapshot } from "@/app/lib/borrow-system/market-hydration"

const POOL_SLUG = "uni-v2-weth-usdc"
const ASSET_SLUG = "uni-v2:usdc"

function usd6ToNumber(value: bigint) {
  return Number(value) / 1_000_000
}

describe("mergeConvexMarketSnapshots", () => {
  it("overlays Convex market liquidity onto pool + asset snapshots", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const before = usd6ToNumber(state.markets[POOL_SLUG]!.snapshot.totalLiquidityUsd6)

    const snapshots: ConvexMarketSnapshot[] = [
      {
        slug: POOL_SLUG,
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
        slug: ASSET_SLUG,
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

    const next = mergeConvexMarketSnapshots(state, snapshots)
    expect(next).not.toBe(state)
    expect(usd6ToNumber(next.markets[POOL_SLUG]!.snapshot.totalLiquidityUsd6)).toBe(33_000_000)
    expect(usd6ToNumber(next.markets[POOL_SLUG]!.snapshot.availableUsd6)).toBe(11_000_000)
    expect(usd6ToNumber(next.assets[ASSET_SLUG]!.snapshot.availableLiquidityUsd6)).toBe(3_000_000)
    expect(usd6ToNumber(next.assets[ASSET_SLUG]!.snapshot.totalBorrowedUsd6)).toBe(7_000_000)
    // the overlay actually changed the value
    expect(usd6ToNumber(next.markets[POOL_SLUG]!.snapshot.totalLiquidityUsd6)).not.toBe(before)
  })

  it("p1-07: hydrates feeApyWad from supplyApyPct, not borrowAprPct", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const next = mergeConvexMarketSnapshots(state, [
      {
        slug: POOL_SLUG,
        scope: "pool",
        suppliedUsd: 33_000_000,
        borrowedUsd: 22_000_000,
        availableUsd: 11_000_000,
        utilizationPct: 66,
        supplyApyPct: 2.4,
        borrowAprPct: 9.9,
        tvlUsd: 33_000_000,
        volumeUsd: 4_000_000,
        feesUsd: 2_600,
      },
    ])
    // wadFromPct(2.4) — must NOT track borrow 9.9
    const feeApy = Number(next.markets[POOL_SLUG]!.snapshot.feeApyWad) / 1e18
    expect(feeApy).toBeCloseTo(0.024, 6)
    expect(feeApy).not.toBeCloseTo(0.099, 3)
  })

  it("leaves wallet positions untouched", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const next = mergeConvexMarketSnapshots(state, [
      {
        slug: POOL_SLUG,
        scope: "pool",
        suppliedUsd: 1,
        borrowedUsd: 0,
        availableUsd: 1,
        utilizationPct: 0,
        supplyApyPct: 0,
        borrowAprPct: 1,
        tvlUsd: 1,
        volumeUsd: 0,
        feesUsd: 0,
      },
    ])
    expect(next.accounts).toBe(state.accounts)
  })

  it("returns the SAME state ref when re-merging identical snapshots (regression: M-11)", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const snapshots: ConvexMarketSnapshot[] = [
      {
        slug: POOL_SLUG,
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
        slug: ASSET_SLUG,
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
    const first = mergeConvexMarketSnapshots(state, snapshots)
    expect(first).not.toBe(state)
    // A second, identical emit must NOT allocate a new object — otherwise every re-emit
    // re-renders the tree and re-fires every page-live async read across all clients.
    expect(mergeConvexMarketSnapshots(first, snapshots)).toBe(first)
  })

  it("returns the same state ref for empty or non-matching snapshots", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    expect(mergeConvexMarketSnapshots(state, [])).toBe(state)
    expect(
      mergeConvexMarketSnapshots(state, [
        {
          slug: "does-not-exist",
          scope: "pool",
          suppliedUsd: 1,
          borrowedUsd: 0,
          availableUsd: 1,
          utilizationPct: 0,
          supplyApyPct: 0,
          borrowAprPct: 1,
          tvlUsd: 1,
          volumeUsd: 0,
          feesUsd: 0,
        },
      ]),
    ).toBe(state)
  })

  it("overlays list identity, LTV, and premium from Convex snapshots", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const next = mergeConvexMarketSnapshots(state, [
      {
        slug: POOL_SLUG,
        scope: "pool",
        name: "Convex Pool Name",
        maxLtvPct: 77.5,
        premiumBps: 42,
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
    ])
    expect(next.markets[POOL_SLUG]!.display.name).toBe("Convex Pool Name")
    expect(next.markets[POOL_SLUG]!.listPremiumBps).toBe(42)
    const ltv = Number(next.markets[POOL_SLUG]!.riskConfig.collateralFactorWad) / 1e18
    expect(ltv).toBeCloseTo(0.775, 6)
  })

  // Prod 2026-09-23: the browser valued the dev wallet's cbBTC/USDC LP at its build-time price
  // ($32.5K) while the server valued pledges at the live $42.2K.
  it("takes the pool's live LP price from the snapshot", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const hydrated = mergeConvexMarketSnapshots(state, [
      {
        slug: POOL_SLUG,
        scope: "pool",
        suppliedUsd: 1,
        borrowedUsd: 0,
        availableUsd: 1,
        utilizationPct: 0,
        supplyApyPct: 2,
        borrowAprPct: 4,
        tvlUsd: 1,
        volumeUsd: 0,
        feesUsd: 0,
        lpPriceUsd: 42_120.87,
      },
    ])
    expect(usd6ToNumber(hydrated.markets[POOL_SLUG]!.snapshot.lpTokenPriceUsd6)).toBeCloseTo(42_120.87, 6)
  })
})
