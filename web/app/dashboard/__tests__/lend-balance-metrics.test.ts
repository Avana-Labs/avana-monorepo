import { describe, expect, it } from "vitest"
import {
  buildLendBalanceMetrics,
  buildLendDashboardMetrics,
  lendYieldGeneratedPct,
  projectLendPortfolioEarningsUsd,
  projectLendSimpleEarningsUsd,
} from "@/app/dashboard/dashboard-tab-metrics"
import type { PortfolioLendTabData, PortfolioSupplyPosition } from "@/app/lib/data/providers/portfolio"

function investment(
  partial: Partial<PortfolioSupplyPosition> & Pick<PortfolioSupplyPosition, "id" | "symbol">,
): PortfolioSupplyPosition {
  return {
    name: partial.symbol,
    balance: partial.suppliedUsd ?? 0,
    priceUsd: 1,
    suppliedUsd: 0,
    earnedUsd: 0,
    dailyEarnedUsd: 0,
    apyPct: 0,
    ...partial,
  }
}

const emptyTab: PortfolioLendTabData = { investments: [], positions: [], strategyBuckets: [], history: [] }

describe("buildLendBalanceMetrics — wallet aggregate formulas", () => {
  it("exposes eight growth metrics and omits rewards from the balance snapshot", () => {
    const data: PortfolioLendTabData = {
      ...emptyTab,
      investments: [
        investment({
          id: "a",
          symbol: "USDC",
          suppliedUsd: 90_000,
          principalUsd: 88_000,
          interestUsd: 2_000,
          earnedUsd: 2_050,
          rewardsEarnedUsd: 50,
          apyPct: 5,
        }),
        investment({
          id: "b",
          symbol: "WETH",
          suppliedUsd: 10_000,
          principalUsd: 9_500,
          interestUsd: 500,
          earnedUsd: 520,
          rewardsEarnedUsd: 20,
          apyPct: 20,
        }),
      ],
    }

    const balance = buildLendBalanceMetrics(data)
    expect(balance.totalSuppliedUsd).toBeCloseTo(100_000, 6)
    // Supplied-weighted Net APY: (90k*5 + 10k*20) / 100k = 6.5 — not (5+20)/2 = 12.5
    expect(balance.netApyPct).toBeCloseTo(6.5, 6)
    expect(balance.interestEarnedUsd).toBeCloseTo(2_500, 6)
    // Yield = 2500 / (88000+9500) = 2500/97500
    expect(balance.yieldGeneratedPct).toBeCloseTo((2_500 / 97_500) * 100, 6)
    expect(Object.keys(balance)).not.toContain("rewardsEarnedUsd")

    // Per-position simple sum ≡ TotalSupplied × NetAPY × days/365
    expect(balance.projectedEarnings1dUsd).toBeCloseTo(100_000 * 0.065 * (1 / 365), 4)
    expect(balance.projectedEarnings30dUsd).toBeCloseTo(100_000 * 0.065 * (30 / 365), 4)
    expect(balance.projectedEarnings90dUsd).toBeCloseTo(100_000 * 0.065 * (90 / 365), 4)
    expect(balance.projectedEarnings6mUsd).toBeCloseTo(100_000 * 0.065 * (182.5 / 365), 4)
  })

  it("returns zeros for an empty wallet", () => {
    expect(buildLendBalanceMetrics(emptyTab)).toEqual({
      totalSuppliedUsd: 0,
      netApyPct: 0,
      interestEarnedUsd: 0,
      yieldGeneratedPct: 0,
      projectedEarnings1dUsd: 0,
      projectedEarnings30dUsd: 0,
      projectedEarnings90dUsd: 0,
      projectedEarnings6mUsd: 0,
      accrualSinceMs: null,
    })
  })

  it("keeps rewards available on buildLendDashboardMetrics for Claim UI", () => {
    const data: PortfolioLendTabData = {
      ...emptyTab,
      investments: [
        investment({
          id: "a",
          symbol: "USDC",
          suppliedUsd: 1_000,
          interestUsd: 10,
          earnedUsd: 15,
          rewardsEarnedUsd: 5,
          apyPct: 4,
          principalUsd: 990,
        }),
      ],
      rewardsSummary: { claimableUsd: 5, totalEarnedUsd: 15 },
    }
    const legacy = buildLendDashboardMetrics(data)
    expect(legacy.rewardsEarnedUsd).toBeCloseTo(5, 6)
    expect(legacy.claimableRewardsUsd).toBeCloseTo(5, 6)
    expect(legacy.interestEarnedUsd).toBeCloseTo(10, 6)
  })
})

describe("lend projection helpers", () => {
  it("uses simple (linear) interest, not compound", () => {
    // Compound for 1Y at 10% on $1000 would be ~$100; simple is exactly $100.
    expect(projectLendSimpleEarningsUsd(1_000, 10, 365)).toBeCloseTo(100, 6)
    // 1 day is 1/365 of annual — not (1.10)^(1/365)-1 which is slightly less.
    const simple1d = projectLendSimpleEarningsUsd(1_000, 10, 1)
    const compound1d = 1_000 * (Math.pow(1.1, 1 / 365) - 1)
    expect(simple1d).toBeCloseTo((1_000 * 0.1) / 365, 8)
    expect(simple1d).toBeGreaterThan(compound1d)
  })

  it("portfolio projection matches weighted Net APY path", () => {
    const investments = [
      { suppliedUsd: 90_000, apyPct: 5 },
      { suppliedUsd: 10_000, apyPct: 20 },
    ]
    const fromLegs = projectLendPortfolioEarningsUsd(investments, 30)
    const fromBlend = 100_000 * 0.065 * (30 / 365)
    expect(fromLegs).toBeCloseTo(fromBlend, 6)
  })
})

describe("lendYieldGeneratedPct", () => {
  it("divides interest by principal, not by current supplied (which includes interest)", () => {
    const pct = lendYieldGeneratedPct(2_840, [{ suppliedUsd: 42_840, principalUsd: 40_000, interestUsd: 2_840 }])
    expect(pct).toBeCloseTo(7.1, 6)
    // Wrong denominator would be 2840/42840 ≈ 6.63%
    expect(pct).not.toBeCloseTo((2_840 / 42_840) * 100, 2)
  })

  it("returns 0 when principal is zero", () => {
    expect(lendYieldGeneratedPct(10, [{ suppliedUsd: 10, principalUsd: 0 }])).toBe(0)
  })
})
