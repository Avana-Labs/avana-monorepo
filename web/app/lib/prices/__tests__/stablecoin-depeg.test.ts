import { afterEach, describe, expect, it } from "vitest"
import { canonicalPriceUsd, resetCanonicalPrices, setCanonicalPrices } from "@/app/lib/prices/canonical"
import { formatTokenPrice } from "@/app/lib/prices/format"
import { lpTokenPriceUsd, normalizeWeights } from "@/app/lib/prices/lp-token-price"

afterEach(() => resetCanonicalPrices())

describe("stablecoin depeg flows through the stack (C5)", () => {
  it("does not permanently assume USDC/USDT/DAI/GHO = 1 — live depeg is reflected", () => {
    setCanonicalPrices({ usdc: 1.0, usdt: 0.999, dai: 1.001, gho: 0.998 })
    expect(canonicalPriceUsd("USDT")).toBe(0.999)
    expect(canonicalPriceUsd("DAI")).toBe(1.001)
    expect(canonicalPriceUsd("GHO")).toBe(0.998)
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
