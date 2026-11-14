import { describe, expect, it } from "vitest"
import { canonicalPriceMap, canonicalPriceUsd } from "@/app/lib/prices/canonical"
import { sandboxBaselinePriceUsd } from "@/app/lib/prices/sandbox-baseline-prices"
import { SWAP_ASSETS } from "@/app/lib/swap-system/catalog"

describe("canonical price basis", () => {
  it("resolves known token prices from the single snapshot", () => {
    expect(canonicalPriceUsd("ETH")).toBe(1934)
    expect(canonicalPriceUsd("eth")).toBe(1934) // case-insensitive
    expect(canonicalPriceUsd("USDC")).toBe(1)
    expect(canonicalPriceUsd("WBTC")).toBe(65_000)
  })

  it("returns undefined for unknown symbols (never a misleading $1 default)", () => {
    expect(canonicalPriceUsd("NOTATOKEN")).toBeUndefined()
    expect(canonicalPriceUsd("")).toBeUndefined()
  })

  it("agrees with the valuation basis used by detail tiles (one source, not two copies)", () => {
    // Detail tiles value via sandboxBaselinePriceUsd; the list/pool basis must match it
    // exactly so the same token never shows two different prices one click apart.
    for (const sym of ["ETH", "USDC", "USDT", "WBTC", "AAVE", "LINK"]) {
      expect(canonicalPriceUsd(sym)).toBe(sandboxBaselinePriceUsd(sym))
    }
  })

  it("exposes a priceKey-keyed map for the pool oracle path", () => {
    const map = canonicalPriceMap()
    expect(map.eth).toBe(1934)
    expect(map.usdc).toBe(1)
  })
})

describe("swap catalog reads the canonical basis (no drift-prone literals)", () => {
  it("prices every non-LP swap asset from the canonical snapshot", () => {
    for (const asset of SWAP_ASSETS) {
      if (asset.isLpToken) continue
      expect(asset.priceUsd).toBe(canonicalPriceUsd(asset.symbol))
    }
  })
})
