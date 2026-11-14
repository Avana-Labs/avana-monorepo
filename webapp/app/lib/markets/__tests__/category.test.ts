import { describe, expect, it } from "vitest"
import { categorizeMarket, matchesCategory } from "@/app/lib/markets/category"

describe("market categorization", () => {
  it("buckets BTC and ETH families by token", () => {
    expect(categorizeMarket("WBTC")).toBe("btc")
    expect(categorizeMarket("cbBTC")).toBe("btc")
    expect(categorizeMarket("wstETH")).toBe("eth")
    expect(categorizeMarket("WETH")).toBe("eth")
  })

  it("treats fiat-pegged stables as forex and governance tokens as utility", () => {
    expect(categorizeMarket("USDC")).toBe("forex")
    expect(categorizeMarket("EURC")).toBe("forex")
    expect(categorizeMarket("GHO")).toBe("forex")
    expect(categorizeMarket("AAVE")).toBe("utility")
    expect(categorizeMarket("UNI")).toBe("utility")
  })

  it("falls back to smart for anything uncategorized", () => {
    expect(categorizeMarket("MOG")).toBe("smart")
    expect(categorizeMarket("")).toBe("smart")
    expect(categorizeMarket(null)).toBe("smart")
  })

  it("matchesCategory always passes for the 'all' chip", () => {
    expect(matchesCategory("AAVE", "all")).toBe(true)
    expect(matchesCategory("WBTC", "btc")).toBe(true)
    expect(matchesCategory("WBTC", "eth")).toBe(false)
  })
})
