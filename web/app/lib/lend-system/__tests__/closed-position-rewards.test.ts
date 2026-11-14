import { describe, expect, it } from "vitest"
import { buildPortfolioLendData, buildLendWalletSnapshot } from "@/app/lib/lend-system/read-model"
import { buildMockLendSystemStateWithSeedPosition } from "@/app/lib/lend-system/mock"

describe("closed lend position rewards", () => {
  it("keeps claimable rewards in wallet summaries after a position is closed", () => {
    const state = buildMockLendSystemStateWithSeedPosition("wallet-1")

    state.positions["wallet-1:eth"] = {
      ...state.positions["wallet-1:eth"]!,
      currentSuppliedAmount: 0,
      suppliedValueUsd: 0,
      interestEarned: 0,
      rewardsEarnedUsd: 64,
      principalAmount: 0,
      scaledBalance: 0,
      status: "closed",
    }

    const portfolio = buildPortfolioLendData("wallet-1", state, [])
    const walletSnapshot = buildLendWalletSnapshot("wallet-1", state, [])

    expect(portfolio.investments).toHaveLength(0)
    expect(portfolio.rewardsSummary?.claimableUsd).toBe(64)
    expect(portfolio.rewardsSummary?.totalEarnedUsd).toBe(64)
    expect(walletSnapshot.metrics.totalEarnedUsd).toBe(64)
    expect(walletSnapshot.metrics.rewardsEarnedUsd).toBe(64)
  })
})
