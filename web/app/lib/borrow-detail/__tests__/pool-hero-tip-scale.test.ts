import { describe, expect, it } from "vitest"
import { buildPoolDetail } from "@/app/lib/borrow-detail/pool.mock"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { mergeConvexMarketSnapshots } from "@/app/lib/borrow-system/market-hydration"
import { resolvePoolDetailFromState } from "@/app/lib/borrow-system/read-model"
import { borrowPoolCapacityLabels } from "@/app/lib/convex-seed/build-seed"

const SLUG = "uni-v3-stable-dai-usdc"
const WALLET = "demo-wallet"

describe("pool detail hero series stay on market tip scale", () => {
  it("Borrowed hero base is tip TVL − available, not spoke.liquidityUsd (~$1.25B)", () => {
    const state = buildMockBorrowSystemState(WALLET)
    const hydrated = mergeConvexMarketSnapshots(state, [
      {
        slug: SLUG,
        scope: "pool",
        suppliedUsd: 63_068_495,
        borrowedUsd: 35_375_119,
        availableUsd: 27_693_376,
        utilizationPct: 56.09,
        supplyApyPct: 1.59,
        borrowAprPct: 3.34,
        tvlUsd: 63_068_495,
        volumeUsd: 0,
        feesUsd: 0,
        maxLtvPct: 92,
      },
    ])
    const detail = resolvePoolDetailFromState(hydrated, WALLET, SLUG)
    expect(detail).not.toBeNull()
    if (!detail) return

    const borrowedSeries = detail.heroMetric.series.borrowed["1Y"]
    const lastBorrowed = borrowedSeries.points[borrowedSeries.points.length - 1]?.v ?? 0
    // Must be ~$35M tip scale, never ~$1.2B (spoke $1.25B − $27.7M available).
    expect(lastBorrowed).toBeGreaterThan(20_000_000)
    expect(lastBorrowed).toBeLessThan(80_000_000)
    expect(lastBorrowed).toBeLessThan(200_000_000)

    const caps = borrowPoolCapacityLabels(63_068_495, 27_693_376)
    expect(caps.depositCapacityLabel).not.toBe("$497.0M")
    expect(caps.depositCapacityLabel).toMatch(/\$1(10|11)\.0M|\$110M/)
  })

  it("catalog-only buildPoolDetail uses row.tvlUsd for hero bases", () => {
    const state = buildMockBorrowSystemState(WALLET)
    const row = Object.values(state.markets).find((m) => m.id === SLUG)
    expect(row).toBeDefined()
    // Force a small tip-scale row through buildPoolDetail directly via resolve after merge
    const detail = buildPoolDetail({
      ...resolvePoolDetailFromState(state, WALLET, SLUG)!.row,
      tvlUsd: 63_000_000,
      availableUsd: 28_000_000,
    })
    const borrowed = detail.heroMetric.series.borrowed["1Y"].points.at(-1)?.v ?? 0
    expect(borrowed).toBeLessThan(100_000_000)
  })
})
