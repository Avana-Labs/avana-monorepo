import { describe, expect, it } from "vitest"
import { computeAssetAllocationRows } from "@/app/lib/borrow-detail/allocation"
import type { BorrowPoolRow } from "@/app/lib/borrow-sim"
import type { SpokeBorrowableRecord } from "@/app/lib/borrow-system/registry"

const visual = { symbol: "X", shortLabel: "X", bgClass: "", textClass: "" }

const pool = (id: string, tvlUsd: number, availableUsd: number): BorrowPoolRow =>
  ({
    id,
    name: id,
    venue: "Uniswap v3",
    feeTier: "0.3%",
    tvlUsd,
    spoke: "core",
    ltv: 0.8,
    dexes: [],
    borrowableTokens: [],
    aprMin: 3,
    aprMax: 5,
    availableUsd,
    riskPremiumBps: 40,
    visuals: [visual, visual],
    collateralExampleUsd: 1000,
    trendUp: true,
  }) as unknown as BorrowPoolRow

const asset = (marketIds: string[]): SpokeBorrowableRecord =>
  ({
    id: "usdc",
    marketIds,
    totalBorrowedUsd: 6_000_000,
    availableUsd: 4_000_000,
  }) as unknown as SpokeBorrowableRecord

describe("computeAssetAllocationRows utilization", () => {
  it("derives utilization from the pool's real economics, not a fabricated formula (#36)", () => {
    // 80% borrowed: (10M - 2M) / 10M ; 25% borrowed: (8M - 6M) / 8M.
    const rows = computeAssetAllocationRows(asset(["p1", "p2"]), [
      pool("p1", 10_000_000, 2_000_000),
      pool("p2", 8_000_000, 6_000_000),
    ])
    const byId = Object.fromEntries(rows.map((r) => [r.pool.id, r.utilizationPct]))
    expect(byId.p1).toBe(80)
    expect(byId.p2).toBe(25)
  })

  it("reports 0% for an unfunded pool instead of a fabricated floor", () => {
    const [row] = computeAssetAllocationRows(asset(["p1"]), [pool("p1", 0, 0)])
    expect(row.utilizationPct).toBe(0)
  })
})
