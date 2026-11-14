import { describe, expect, it } from "vitest"
import { maxMultiplyCollateralAmount } from "@/app/lib/multiply-system/collateral-limits"
import { deriveMultiplyCollateralBudgetUsd } from "@/app/lib/multiply-system/wallet-collateral-budget"

const markets = {
  "usdc-usdt": { collateralAsset: { symbol: "USDC" } },
  "usdc-gho": { collateralAsset: { symbol: "USDC" } },
  "eth-usdt": { collateralAsset: { symbol: "ETH" } },
}

describe("deriveMultiplyCollateralBudgetUsd", () => {
  it("derives a per-market budget from the wallet's liquid holding of the collateral token when no explicit available row exists", () => {
    const budget = deriveMultiplyCollateralBudgetUsd({
      explicitBucketsUsd: {},
      markets,
      liquidHoldings: [{ symbol: "USDC", valueUsd: 25_000 }],
    })

    // A market whose collateral the wallet actually holds is now openable
    // instead of showing "Max 0 USDC".
    expect(budget["usdc-usdt"]).toBe(25_000)
    expect(budget["usdc-gho"]).toBe(25_000)
    // No ETH held → no derived budget for the ETH market.
    expect(budget["eth-usdt"]).toBeUndefined()

    // The derived budget unblocks the open flow: Max is now > 0.
    const max = maxMultiplyCollateralAmount(8_400_000, 1, budget["usdc-usdt"])
    expect(max).not.toBeNull()
    expect(max!).toBeGreaterThan(0)
  })

  it("matches the collateral symbol case-insensitively", () => {
    const budget = deriveMultiplyCollateralBudgetUsd({
      explicitBucketsUsd: {},
      markets: { "eth-usdt": { collateralAsset: { symbol: "ETH" } } },
      liquidHoldings: [{ symbol: "eth", valueUsd: 4_000 }],
    })
    expect(budget["eth-usdt"]).toBe(4_000)
  })

  it("prefers an explicit available row over the derived liquid fallback", () => {
    const budget = deriveMultiplyCollateralBudgetUsd({
      explicitBucketsUsd: { "usdc-usdt": 10_000 },
      markets,
      liquidHoldings: [{ symbol: "USDC", valueUsd: 25_000 }],
    })
    // Explicit multiply "available" bucket wins; the liquid holding is only a fallback.
    expect(budget["usdc-usdt"]).toBe(10_000)
    // Sibling market with no explicit row still falls back to the liquid holding.
    expect(budget["usdc-gho"]).toBe(25_000)
  })

  it("sums multiple liquid holdings of the same collateral symbol", () => {
    const budget = deriveMultiplyCollateralBudgetUsd({
      explicitBucketsUsd: {},
      markets: { "usdc-usdt": { collateralAsset: { symbol: "USDC" } } },
      liquidHoldings: [
        { symbol: "USDC", valueUsd: 10_000 },
        { symbol: "USDC", valueUsd: 5_000 },
      ],
    })
    expect(budget["usdc-usdt"]).toBe(15_000)
  })

  it("ignores non-positive, non-finite, and symbol-less holdings", () => {
    const budget = deriveMultiplyCollateralBudgetUsd({
      explicitBucketsUsd: {},
      markets,
      liquidHoldings: [
        { symbol: "USDC", valueUsd: 0 },
        { symbol: "ETH", valueUsd: Number.NaN },
        { symbol: "", valueUsd: 100 },
      ],
    })
    expect(budget["usdc-usdt"]).toBeUndefined()
    expect(budget["eth-usdt"]).toBeUndefined()
  })
})

// Prod 2026-09-23: the dev wallet holds 119.05 AAVE bought at ~$105; the Multiply form offered
// 90.33 AAVE because it divided that cost basis by today's $138 price.
describe("deriveMultiplyCollateralBudgetUsd live valuation", () => {
  it("values a liquid holding at amount × today's price, not its cost basis", async () => {
    const { setCanonicalPrices, resetCanonicalPrices } = await import("@/app/lib/prices/canonical")
    setCanonicalPrices({ AAVE: 138.4 })
    try {
      const budget = deriveMultiplyCollateralBudgetUsd({
        explicitBucketsUsd: {},
        markets: { "aave-gho": { collateralAsset: { symbol: "AAVE" } } },
        liquidHoldings: [{ symbol: "AAVE", valueUsd: 12_499.88, amount: 119.05 }],
      })
      expect(budget["aave-gho"]! / 138.4).toBeCloseTo(119.05, 6)
    } finally {
      resetCanonicalPrices()
    }
  })
})
