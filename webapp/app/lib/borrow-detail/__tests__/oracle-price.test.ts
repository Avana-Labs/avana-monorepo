import { describe, expect, it } from "vitest"
import { injectPoolOraclePrice } from "@/app/lib/borrow-detail/convex-detail"
import type { QuickStat } from "@/app/lib/borrow-detail/types"

const stats = (oracle: string): QuickStat[] => [
  { id: "price", label: "Price", value: oracle },
  { id: "available", label: "Available Liquidity", value: "$1.0M" },
]

describe("injectPoolOraclePrice", () => {
  it("shows the pair spot rate priced in the quote leg (base ÷ quote, with the quote symbol)", () => {
    // WETH at $3,102.55, USDC at $1 → 3,102.55 WETH-per-USDC, quoted in USDC (≈ WETH's USD price).
    const out = injectPoolOraclePrice(stats("$3,450.00"), { weth: 3102.55, usdc: 1 }, "WETH", "USDC")
    expect(out.find((s) => s.id === "price")?.value).toBe("3,102.55 USDC")
    // Other stats are untouched.
    expect(out.find((s) => s.id === "available")?.value).toBe("$1.0M")
  })

  it("prices a NON-USD-quoted pool in its quote token, not a mislabeled '$'", () => {
    // cbBTC / WETH: the rate is ~33.7 WETH per cbBTC. It must read "33.71 WETH", never "$33.75".
    const out = injectPoolOraclePrice(stats("$33.60"), { cbbtc: 64251.57, weth: 1905.92 }, "cbBTC", "WETH")
    expect(out.find((s) => s.id === "price")?.value).toBe("33.71 WETH")
    // The Uniswap-style tooltip carries the USD value of the base leg.
    expect(out.find((s) => s.id === "price")?.tooltip).toContain("1 cbBTC = 33.71 WETH ($64,251.57)")
  })

  it("differs between two pools that share a base but have different quotes", () => {
    // Same base (WBTC), different quote → different rate + quote symbol (the bug this fixes: the
    // base-price version made WBTC/USDC and WBTC/WETH identical).
    const usdc = injectPoolOraclePrice(stats("x"), { wbtc: 64426.09, usdc: 1, weth: 1911.27 }, "WBTC", "USDC")
    const weth = injectPoolOraclePrice(stats("x"), { wbtc: 64426.09, usdc: 1, weth: 1911.27 }, "WBTC", "WETH")
    expect(usdc.find((s) => s.id === "price")?.value).toBe("64,426.09 USDC")
    expect(weth.find((s) => s.id === "price")?.value).toBe("33.71 WETH")
  })

  it("uses the same real rate regardless of the hardcoded fixture value", () => {
    // Same asset (WETH), different starting fixtures → one consistent oracle price.
    const a = injectPoolOraclePrice(stats("$3,450.00"), { weth: 3102.55, usdc: 1 }, "WETH", "USDC")
    const b = injectPoolOraclePrice(stats("$99.99"), { weth: 3102.55, usdc: 1 }, "WETH", "USDC")
    expect(a.find((s) => s.id === "price")?.value).toBe(b.find((s) => s.id === "price")?.value)
  })

  it("drops the oracle-price stat (never the fabricated fallback) when unpriced or unavailable", () => {
    // Oracle unavailable → the hardcoded fixture value must not reach the display path.
    const whenNull = injectPoolOraclePrice(stats("$3,450.00"), null, "WETH", "USDC")
    expect(whenNull.find((s) => s.id === "price")).toBeUndefined()
    // Other stats survive.
    expect(whenNull.find((s) => s.id === "available")?.value).toBe("$1.0M")

    // One leg unpriced → still dropped rather than fabricated.
    const whenPartial = injectPoolOraclePrice(stats("$3,450.00"), { usdc: 1 }, "WETH", "USDC")
    expect(whenPartial.find((s) => s.id === "price")).toBeUndefined()
  })
})
