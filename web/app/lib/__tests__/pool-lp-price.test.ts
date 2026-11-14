import { describe, expect, it } from "vitest"
import { BORROW_POOL_CATALOG, poolLpTokenPriceUsd } from "@/app/lib/borrow-sim"
import { canonicalPriceUsd } from "@/app/lib/prices/canonical"
import { lpTokenPriceUsd } from "@/app/lib/prices/lp-token-price"

describe("poolLpTokenPriceUsd — weighted-average of constituents (C8)", () => {
  it("prices every catalog pool as Σ(weightᵢ × priceᵢ) when all legs are priced", () => {
    let pricedPools = 0
    for (const pool of BORROW_POOL_CATALOG) {
      const weighted = lpTokenPriceUsd(pool.constituents, canonicalPriceUsd)
      if (weighted.ok) {
        pricedPools++
        expect(poolLpTokenPriceUsd(pool)).toBeCloseTo(weighted.priceUsd, 9)
      } else {
        // Fallback path: only reached when a leg is unpriced (exotic tokens).
        expect(poolLpTokenPriceUsd(pool)).toBe(Math.max(1, pool.collateralExampleUsd / 2.5))
      }
    }
    // The vast majority of the catalog must price off real component prices, not the fallback.
    expect(pricedPools).toBeGreaterThan(BORROW_POOL_CATALOG.length / 2)
  })

  it("no longer depends on the arbitrary collateralExampleUsd for priced pools", () => {
    const priced = BORROW_POOL_CATALOG.find((p) => lpTokenPriceUsd(p.constituents, canonicalPriceUsd).ok)!
    const bumped = { ...priced, collateralExampleUsd: priced.collateralExampleUsd * 100 }
    expect(poolLpTokenPriceUsd(bumped)).toBeCloseTo(poolLpTokenPriceUsd(priced), 9)
  })

  it("moves with the component prices (WBTC/WETH ≫ stable/stable)", () => {
    const wbtcWeth = BORROW_POOL_CATALOG.find((p) => p.name === "WBTC / WETH")!
    const usdcUsdt = BORROW_POOL_CATALOG.find((p) => p.name === "USDC / USDT")!
    expect(poolLpTokenPriceUsd(wbtcWeth)).toBeGreaterThan(poolLpTokenPriceUsd(usdcUsdt))
    // 0.5·WBTC + 0.5·WETH
    expect(poolLpTokenPriceUsd(wbtcWeth)).toBeCloseTo(
      0.5 * canonicalPriceUsd("WBTC")! + 0.5 * canonicalPriceUsd("WETH")!,
      6,
    )
  })

  it("80/20 WETH/AAVE prices as 0.8·WETH + 0.2·AAVE", () => {
    const pool = BORROW_POOL_CATALOG.find((p) => p.name === "80/20 WETH/AAVE")!
    expect(poolLpTokenPriceUsd(pool)).toBeCloseTo(
      0.8 * canonicalPriceUsd("WETH")! + 0.2 * canonicalPriceUsd("AAVE")!,
      6,
    )
  })

  it("no 2·√(P0·P1) geometric-mean formula: WETH/USDC ≠ 2·√(P0·P1)", () => {
    const pool = BORROW_POOL_CATALOG.find((p) => p.name === "WETH / USDC")!
    const weighted = poolLpTokenPriceUsd(pool)
    const geomMean = 2 * Math.sqrt(canonicalPriceUsd("WETH")! * canonicalPriceUsd("USDC")!)
    expect(weighted).toBeCloseTo(0.5 * canonicalPriceUsd("WETH")! + 0.5 * canonicalPriceUsd("USDC")!, 6)
    expect(weighted).not.toBeCloseTo(geomMean, 1)
  })
})
