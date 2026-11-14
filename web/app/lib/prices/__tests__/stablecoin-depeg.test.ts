import { afterEach, describe, expect, it } from "vitest"
import { canonicalPriceUsd, resetCanonicalPrices, setCanonicalPrices } from "@/app/lib/prices/canonical"
import { formatTokenPrice } from "@/app/lib/prices/format"
import { BORROW_POOL_CATALOG, poolLpTokenPriceUsd } from "@/app/lib/borrow-sim"
import { lpTokenPriceUsd, normalizeWeights } from "@/app/lib/prices/lp-token-price"

afterEach(() => resetCanonicalPrices())

const usdcUsdt = () => BORROW_POOL_CATALOG.find((p) => p.name === "USDC / USDT")!

describe("stablecoin depeg flows through the stack (C5)", () => {
  it("does not permanently assume USDC/USDT/DAI/GHO = 1 — live depeg is reflected", () => {
    setCanonicalPrices({ usdc: 1.0, usdt: 0.999, dai: 1.001, gho: 0.998 })
    expect(canonicalPriceUsd("USDT")).toBe(0.999)
    expect(canonicalPriceUsd("DAI")).toBe(1.001)
    expect(canonicalPriceUsd("GHO")).toBe(0.998)
  })

  it("depeg flows into the weighted LP price: USDC/USDT 50/50 at USDT=0.999 → $0.9995", () => {
    setCanonicalPrices({ usdc: 1, usdt: 0.999 })
    expect(poolLpTokenPriceUsd(usdcUsdt())).toBeCloseTo(0.9995, 9)
  })

  it("a deeper depeg lowers the LP value vs the pegged baseline", () => {
    const pool = usdcUsdt()
    const atPeg = poolLpTokenPriceUsd(pool) // fixture: USDC=USDT=1 → 1.0
    setCanonicalPrices({ usdc: 1, usdt: 0.98 })
    const depegged = poolLpTokenPriceUsd(pool) // 0.5·1 + 0.5·0.98 = 0.99
    expect(atPeg).toBeCloseTo(1.0, 9)
    expect(depegged).toBeCloseTo(0.99, 9)
    expect(depegged).toBeLessThan(atPeg)
  })

  it("depeg flows into a 3-token stable LP (DAI/USDC/USDT)", () => {
    setCanonicalPrices({ dai: 1.001, usdc: 1, usdt: 0.999 })
    const expected = lpTokenPriceUsd(
      normalizeWeights([
        { symbol: "DAI", weight: 1 },
        { symbol: "USDC", weight: 1 },
        { symbol: "USDT", weight: 1 },
      ]),
      canonicalPriceUsd,
    )
    expect(expected.ok).toBe(true)
    if (expected.ok) expect(expected.priceUsd).toBeCloseTo((1.001 + 1 + 0.999) / 3, 9)
  })

  it("a sub-$1 depeg is visible in the price display (not rounded to $1.00)", () => {
    // Sub-$1 prices keep up to 4 decimals, so a depeg reads distinctly from the peg.
    expect(formatTokenPrice(0.999)).toBe("$0.999")
    expect(formatTokenPrice(0.98)).toBe("$0.98")
    expect(formatTokenPrice(0.999)).not.toBe("$1.00")
  })
})
