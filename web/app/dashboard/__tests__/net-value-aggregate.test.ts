import { describe, expect, it } from "vitest"
import { aggregateNetValueUsd } from "@/app/dashboard/use-dashboard-portfolio-summary"
import type { UserAssetBalance } from "@/app/lib/swap-system"

const priceFor = (symbol: string): number | undefined => ({ ETH: 2000, USDC: 1, AAVE: 90 })[symbol.trim().toUpperCase()]

function row(partial: Partial<UserAssetBalance> & { assetId: string; amount: number }): UserAssetBalance {
  return { id: partial.assetId, walletId: "w", sourceType: "wallet", ...partial }
}

describe("aggregateNetValueUsd", () => {
  it("live-prices non-LP tokens by amount × oracle price", () => {
    const rows = [
      row({ assetId: "eth", amount: 0.1, valueUsd: 193 }),
      row({ assetId: "usdc", amount: 300, valueUsd: 300 }),
    ]
    // ETH re-priced to 0.1×2000=200 (not the stale 193); USDC 300.
    expect(aggregateNetValueUsd(rows, priceFor)).toBeCloseTo(500, 6)
  })

  it("keeps debt rows negative (productBalances encodes debt as negative valueUsd)", () => {
    const rows = [
      row({ assetId: "usdc", amount: 1000, valueUsd: 1000, sourceType: "wallet" }),
      row({ assetId: "usdc", amount: 250, valueUsd: -250, sourceType: "multiply_debt" }),
    ]
    // 1000 asset − 250 debt = 750 (debt magnitude re-priced live but stays negative).
    expect(aggregateNetValueUsd(rows, priceFor)).toBeCloseTo(750, 6)
  })

  it("values LP rows on their stored basis (no live token repricing)", () => {
    const rows = [row({ assetId: "eth-usdc-lp", amount: 8, valueUsd: 1000 })]
    expect(aggregateNetValueUsd(rows, priceFor)).toBeCloseTo(1000, 6)
  })

  it("falls back to stored value when a token is unpriced by the oracle", () => {
    const rows = [row({ assetId: "wbtc", amount: 1, valueUsd: 60000 })]
    expect(aggregateNetValueUsd(rows, priceFor)).toBeCloseTo(60000, 6)
  })

  it("does not multiply a Multiply available USD budget by its token price", () => {
    const rows = [
      row({
        assetId: "wsteth",
        amount: 41_666.67,
        valueUsd: 41_666.67,
        sourceType: "multiply_available",
      }),
    ]

    expect(aggregateNetValueUsd(rows, () => 2_982.18)).toBeCloseTo(41_666.67, 6)
  })

  it("is empty-safe", () => {
    expect(aggregateNetValueUsd([], priceFor)).toBe(0)
  })
})
