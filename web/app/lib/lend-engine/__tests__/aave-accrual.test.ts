import { describe, expect, it } from "vitest"
import { applyLendAction } from "@/app/lib/lend-engine/actions"
import { simulateWithdraw } from "@/app/lib/lend-engine/simulation"
import { buildMockLendMarket } from "@/app/lib/lend-system/mock"

describe("lend accrual semantics", () => {
  it("accrues supplied balance from supply APY only, not rewards APY", () => {
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
        walletBalances: { "wallet-1": { [market.marketId]: 5000 } },
        transactions: [],
      },
      {
        type: "deposit",
        walletId: "wallet-1",
        marketId: market.marketId,
        depositAmount: 1000,
        walletBalance: 5000,
        at: openedAt,
      },
      { positionId: "position-1", transactionId: "tx-deposit" },
    )

    const position = depositedState.positions["position-1"]!
    const simulation = simulateWithdraw({
      market: depositedState.markets[market.marketId]!,
      position,
      withdrawAmount: 100,
      now: Date.UTC(2026, 5, 19),
    })

    expect(simulation.before.interestEarned).toBeCloseTo(40, 4)
    expect(simulation.before.suppliedAmount).toBeCloseTo(1040, 4)
  })
})
