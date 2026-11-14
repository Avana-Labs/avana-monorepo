import { describe, expect, it } from "vitest"
import { SANDBOX_BASELINE_PRICES_USD, sandboxBaselinePriceUsd } from "@/app/lib/prices/sandbox-baseline-prices"
import { SWAP_ASSETS } from "@/app/lib/swap-system/catalog"

// Guards the "single price source" fix: lend and multiply catalogs import the shared
// baseline directly (so they cannot drift), and swap's per-asset priceUsd literals must
// stay equal to it. Regression against the old split where ETH read $3,500 on
// lend/multiply but $1,934 on swap — the same token showed a different USD per screen.
describe("single sandbox price source", () => {
  it("ETH is one realistic value everywhere (not the stale $3,500)", () => {
    expect(SANDBOX_BASELINE_PRICES_USD.ETH).toBe(1934)
    expect(SANDBOX_BASELINE_PRICES_USD.WETH).toBe(SANDBOX_BASELINE_PRICES_USD.ETH)
    // ETH-family and majors must sit in the realistic tier, never back near $3.5k.
    expect(SANDBOX_BASELINE_PRICES_USD.WSTETH).toBeLessThan(2500)
    expect(SANDBOX_BASELINE_PRICES_USD.WBTC).toBeLessThan(80000)
  })

  it("swap catalog base-asset prices match the shared baseline", () => {
    for (const asset of SWAP_ASSETS) {
      if (asset.isLpToken) continue
      const baseline = SANDBOX_BASELINE_PRICES_USD[asset.symbol.toUpperCase()]
      if (baseline == null) continue
      expect(asset.priceUsd, `${asset.symbol} swap price must match baseline`).toBe(baseline)
    }
  })

  it("sandboxBaselinePriceUsd is case-insensitive and defaults stables to $1", () => {
    expect(sandboxBaselinePriceUsd("eth")).toBe(1934)
    expect(sandboxBaselinePriceUsd("ETH")).toBe(1934)
    expect(sandboxBaselinePriceUsd("SOME_UNKNOWN_STABLE")).toBe(1)
  })
})
