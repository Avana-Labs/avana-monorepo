import { describe, expect, it } from "vitest"
import { buildPortfolioLendData } from "@/app/lib/lend-system/read-model"
import { buildMockLendSystemStateWithSeedPosition } from "@/app/lib/lend-system/mock"

describe("buildPortfolioLendData rewards", () => {
  it("includes rewards incentives in earned and daily lend metrics", () => {
    const state = buildMockLendSystemStateWithSeedPosition("wallet-1")
    const position = state.positions["wallet-1:eth"]!
    const market = state.markets.eth!

    state.positions["wallet-1:eth"] = {
      ...position,
      currentSuppliedAmount: 10,
      principalAmount: 9.5,
      interestEarned: 0.5,
      rewardsEarnedUsd: 42,
      suppliedValueUsd: 10 * market.assetPriceUsd,
    }

    state.markets.eth = {
      ...market,
      supplyApy: 0.04,
      rewardsApy: 0.02,
      totalApy: 0.06,
    }

    const portfolio = buildPortfolioLendData("wallet-1", state, [])
    const investment = portfolio.investments[0]!

    expect(investment.earnedUsd).toBeCloseTo(0.5 * market.assetPriceUsd + 42, 6)
    // The dashboard lend row shows the canonical SUPPLY APY (0.04), matching /lend and the deposit
    // action — not totalApy (supply + rewards); the daily projection follows that same rate.
    expect(investment.apyPct).toBeCloseTo(4, 6)
    expect(investment.dailyEarnedUsd).toBeCloseTo((investment.suppliedUsd * 0.04) / 365, 6)
  })
})
