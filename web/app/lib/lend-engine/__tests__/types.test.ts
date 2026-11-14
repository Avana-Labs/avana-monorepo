import { describe, expect, it } from "vitest"
import { INITIAL_LIQUIDITY_INDEX, SECONDS_PER_YEAR } from "@/app/lib/lend-engine/constants"
import type { LendDepositSimulation, LendMarket } from "@/app/lib/lend-engine/types"

describe("lend engine constants and types", () => {
  it("defines SECONDS_PER_YEAR and initial liquidity index", () => {
    expect(SECONDS_PER_YEAR).toBe(31_536_000)
    expect(INITIAL_LIQUIDITY_INDEX).toBe(1)
  })

  it("accepts deposit simulation shape", () => {
    const simulation: LendDepositSimulation = {
      action: "deposit",
      input: { marketId: "eth", assetSymbol: "ETH", depositAmount: 1 },
      before: {
        suppliedAmount: 0,
        suppliedValueUsd: 0,
        principalAmount: 0,
        interestEarned: 0,
        rewardsEarnedUsd: 0,
        totalEarnedUsd: 0,
        scaledBalance: 0,
        liquidityIndex: 1,
      },
      after: {
        suppliedAmount: 1,
        suppliedValueUsd: 3500,
        principalAmount: 1,
        interestEarned: 0,
        rewardsEarnedUsd: 0,
        totalEarnedUsd: 0,
        scaledBalance: 1,
        liquidityIndex: 1,
      },
      market: {
        supplyApy: 0.0382,
        rewardsApy: 0,
        totalApy: 0.0382,
        utilization: 0.6133,
        availableLiquidity: 1_000_000,
        totalSupplied: 2_600_000,
      },
      marketBefore: { totalSupplied: 2_600_000, availableLiquidity: 1_000_000, utilization: 0.6133 },
      marketAfter: { totalSupplied: 2_600_001, availableLiquidity: 1_000_001, utilization: 0.6133 },
      validation: { allowed: true, errors: [], warnings: [] },
    }

    expect(simulation.action).toBe("deposit")
  })

  it("accepts lend market shape", () => {
    const market: LendMarket = {
      marketId: "eth",
      chainId: 1,
      rank: 1,
      asset: { symbol: "ETH", name: "Ether", priceUsd: 3500 },
      assetPriceUsd: 3500,
      supplyApy: 0.0382,
      rewardsApy: 0,
      totalApy: 0.0382,
      totalSupplied: 2_600_000,
      totalBorrowed: 1_600_000,
      availableLiquidity: 1_000_000,
      utilization: 0.6133,
      reserveFactor: 0.15,
      status: "active",
      riskTier: "medium",
      liquidityIndex: 1,
      lastAccrualTimestamp: 1_700_000_000_000,
      priceUpdatedAt: 1_700_000_000_000,
    }

    expect(market.marketId).toBe("eth")
  })
})
