import { describe, expect, it } from "vitest"
import { BORROW_POOL_CATALOG } from "@/app/lib/borrow-market-rows"
import { WEIGHT_SUM_TOLERANCE } from "@/app/lib/prices/lp-token-price"

const bySlug = (fragment: string) => BORROW_POOL_CATALOG.filter((p) => p.name.includes(fragment))

describe("pool composition + weights (C6)", () => {
  it("every catalog pool carries constituents whose weights sum to 1", () => {
    expect(BORROW_POOL_CATALOG.length).toBeGreaterThan(0)
    for (const pool of BORROW_POOL_CATALOG) {
      expect(pool.constituents.length).toBeGreaterThan(0)
      const sum = pool.constituents.reduce((s, c) => s + c.weight, 0)
      expect(Math.abs(sum - 1)).toBeLessThanOrEqual(WEIGHT_SUM_TOLERANCE)
      for (const c of pool.constituents) {
        expect(c.weight).toBeGreaterThan(0)
        expect(typeof c.symbol).toBe("string")
      }
    }
  })

  it("plain 2-token pools are equal-weight 50/50", () => {
    const usdcUsdt = BORROW_POOL_CATALOG.find((p) => p.name === "USDC / USDT")
    expect(usdcUsdt).toBeDefined()
    expect(usdcUsdt!.constituents.map((c) => c.weight)).toEqual([0.5, 0.5])
  })

  it("named 3-token stable pools decompose into three equal thirds", () => {
    for (const pool of bySlug("DAI / USDC / USDT")) {
      expect(pool.constituents).toHaveLength(3)
      for (const c of pool.constituents) expect(c.weight).toBeCloseTo(1 / 3, 9)
    }
    const triCrypto = BORROW_POOL_CATALOG.find((p) => p.name === "USDC / WBTC / ETH")
    expect(triCrypto?.constituents.map((c) => c.symbol)).toEqual(["USDC", "WBTC", "ETH"])
  })

  it("80/20 weighted pools decompose to 0.8 / 0.2 in name order", () => {
    for (const pool of bySlug("80/20 ")) {
      expect(pool.constituents).toHaveLength(2)
      const [major, minor] = pool.constituents
      expect(major.weight).toBeCloseTo(0.8, 9)
      expect(minor.weight).toBeCloseTo(0.2, 9)
      // Name reads "80/20 MAJOR/MINOR"
      const [, pair] = pool.name.split(" ")
      const [majorSym] = pair.split("/")
      expect(major.symbol).toBe(majorSym)
    }
  })

  it("single-asset boosted wrappers price as one underlying token", () => {
    const wa = BORROW_POOL_CATALOG.find((p) => p.name === "waUSDC / USDC")
    expect(wa?.constituents).toEqual([{ symbol: "USDC", weight: 1 }])
  })
})
