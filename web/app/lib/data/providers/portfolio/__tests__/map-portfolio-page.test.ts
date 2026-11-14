import { describe, expect, it } from "vitest"
import { mapPortfolioPage } from "@/app/lib/data/providers/portfolio/map-portfolio-page"
import type { PortfolioPageRecords } from "@/app/lib/data/providers/portfolio/source"

// mapPortfolioPage builds the whole portfolio page; these fixtures supply every
// array/field it dereferences. Snapshots may be empty (getRangeData falls back).
function makeRecords(overrides: Partial<PortfolioPageRecords> = {}): PortfolioPageRecords {
  const base = {
    walletProfile: { id: "w1", walletAddress: "0x0000000000000000000000000000000000000001" },
    snapshots: [],
    supplies: [],
    debts: [],
    collaterals: [],
    multiplyCreditLines: {
      walletProfileId: "w1",
      approvedUsd: 0,
      liquidationThresholdUsd: 0,
      averageHealthFactor: null,
      currentLtvPct: 0,
      totalBorrowedUsd: 0,
      totalCollateralUsd: 0,
    },
    multiplyCollaterals: [],
    multiplyPositions: [],
    openOrders: [],
    twapOrders: [],
    activity: [],
    strategies: [],
    rewards: {},
  }
  return { ...base, ...overrides } as unknown as PortfolioPageRecords
}

function debt(overrides: Record<string, unknown> = {}) {
  return {
    id: "d1",
    walletProfileId: "w1",
    poolId: "weth-usdc",
    debtAssetSymbol: "USDC",
    borrowedUsd: 100,
    borrowAprPct: 6,
    accruedInterestUsd: 0,
    dailyInterestUsd: 0,
    ...overrides,
  }
}

function supply(id: string, suppliedUsd: number, apyPct: number) {
  return { id, walletProfileId: "w1", suppliedUsd, earnedUsd: 0, dailyEarnedUsd: 0, apyPct }
}

describe("mapPortfolioPage — debt without collateral (A1)", () => {
  it("does not throw and still renders the debt when there are no collateral rows", () => {
    const records = makeRecords({ debts: [debt()] as never, collaterals: [] })
    expect(() => mapPortfolioPage(records)).not.toThrow()
    const page = mapPortfolioPage(records)
    expect(page.borrow.debtPositions).toHaveLength(1)
    // A debt-derived placeholder pool is used instead of crashing on undefined.
    expect(page.borrow.debtPositions[0].pool.id).toBe("weth-usdc")
    expect(page.borrow.debtPositions[0].borrowedUsd).toBe(100)
  })
})

describe("mapPortfolioPage — lend average APY is balance-weighted (C4)", () => {
  it("weights by deposited balance instead of a flat mean", () => {
    const records = makeRecords({
      supplies: [supply("s1", 10_000, 2), supply("s2", 100, 40)] as never,
    })
    const page = mapPortfolioPage(records)
    // Flat mean would be 21%; true blended is (2*10000 + 40*100)/10100 ≈ 2.376%.
    expect(page.tabs.lend.averageApyPct).toBeCloseTo(2.376, 2)
    expect(page.tabs.lend.averageApyPct).toBeLessThan(3)
  })
})
