import { describe, expect, it } from "vitest"
import { PRICE_FIXTURE } from "@/app/lib/prices/price-fixture"
import { SANDBOX_BASELINE_PRICES_USD } from "@/app/lib/prices/sandbox-baseline-prices"

describe("PRICE_FIXTURE (C0) — deterministic seed/fallback", () => {
  it("is the single source behind the legacy baseline export", () => {
    expect(SANDBOX_BASELINE_PRICES_USD).toBe(PRICE_FIXTURE)
  })

  it("holds finite, positive USD prices under UPPERCASE keys", () => {
    for (const [symbol, price] of Object.entries(PRICE_FIXTURE)) {
      expect(symbol).toBe(symbol.toUpperCase())
      expect(Number.isFinite(price)).toBe(true)
      expect(price).toBeGreaterThan(0)
    }
  })

  it("covers the core assets the sandbox values positions in", () => {
    for (const s of ["ETH", "WETH", "WBTC", "USDC", "USDT", "DAI", "GHO", "AAVE"]) {
      expect(PRICE_FIXTURE[s]).toBeGreaterThan(0)
    }
  })
})
