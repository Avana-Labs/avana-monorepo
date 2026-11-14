import { describe, expect, it } from "vitest"
import { applyLendActions } from "@/app/lib/lend-engine/batch"
import { buildMockLendMarket } from "@/app/lib/lend-system/mock"

describe("applyLendActions", () => {
  it("supports wallet-level claim actions in mixed batches", () => {
    const market = buildMockLendMarket("eth")

    const result = applyLendActions(
      {
        now: market.lastAccrualTimestamp,
        markets: { [market.marketId]: market },
        positions: {
          "wallet-1:eth": {
            positionId: "wallet-1:eth",
            walletId: "wallet-1",
            marketId: market.marketId,
            asset: "ETH",
            principalAmount: 10,
            scaledBalance: 10,
            liquidityIndexAtLastAction: 1,
            currentSuppliedAmount: 10,
            interestEarned: 0,
            rewardsEarnedUsd: 25,
            suppliedValueUsd: 35_000,
            openedAt: market.lastAccrualTimestamp,
            updatedAt: market.lastAccrualTimestamp,
            status: "active",
          },
        },
        walletBalances: { "wallet-1": { [market.marketId]: 5 } },
        transactions: [],
      },
      [
        {
          type: "claim",
          walletId: "wallet-1",
          at: market.lastAccrualTimestamp + 1_000,
        },
      ],
    )

    expect(result.positions["wallet-1:eth"]?.rewardsEarnedUsd).toBe(0)
    expect(result.transactions).toHaveLength(1)
    expect(result.transactions[0]?.kind).toBe("claim")
  })
})
