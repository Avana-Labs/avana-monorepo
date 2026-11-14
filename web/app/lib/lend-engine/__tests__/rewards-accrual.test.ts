import { describe, expect, it } from "vitest"
import { applyLendAction } from "@/app/lib/lend-engine/actions"
import { simulateWithdraw } from "@/app/lib/lend-engine/simulation"
import { buildMockLendMarket } from "@/app/lib/lend-system/mock"

describe("lend rewards accrual", () => {
  it("accrues rewards APY as separate non-withdrawable incentives", () => {
    const openedAt = Date.UTC(2025, 5, 19)
    const market = {
      ...buildMockLendMarket("eth"),
      supplyApy: 0.04,
      rewardsApy: 0.1,
      totalApy: 0.14,
      lastAccrualTimestamp: openedAt,
      priceUpdatedAt: openedAt,
    }

    const depositedState = applyLendAction(
      {
        now: openedAt,
        markets: { [market.marketId]: market },
        positions: {},
        walletBalances: { "wallet-1": { [market.marketId]: 5 } },
        transactions: [],
      },
      {
        type: "deposit",
        walletId: "wallet-1",
        marketId: market.marketId,
        depositAmount: 1,
        walletBalance: 5,
        at: openedAt,
      },
      { positionId: "position-1", transactionId: "tx-deposit" },
    )

    const position = depositedState.positions["position-1"]!
    const simulation = simulateWithdraw({
      market: depositedState.markets[market.marketId]!,
      position,
      withdrawAmount: 0.5,
      now: Date.UTC(2026, 5, 19),
    })

    expect(simulation.before.interestEarned).toBeCloseTo(0.04, 6)
    // Rewards USD tracks the single sandbox baseline ETH price (~$1,934, was $3,500).
    expect(simulation.before.rewardsEarnedUsd).toBeCloseTo(201.14, 2)
    expect(simulation.after.rewardsEarnedUsd).toBeCloseTo(simulation.before.rewardsEarnedUsd, 6)
  })
})
