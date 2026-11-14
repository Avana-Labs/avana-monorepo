import { afterEach, describe, expect, it } from "vitest"
import { canonicalPriceUsd, resetCanonicalPrices, setCanonicalPrices } from "@/app/lib/prices/canonical"
import { sandboxBaselinePriceUsd } from "@/app/lib/prices/sandbox-baseline-prices"
import { PRICE_FIXTURE } from "@/app/lib/prices/price-fixture"

afterEach(() => resetCanonicalPrices())

describe("canonical price store (C3) — fixture seed, live overlay", () => {
  it("resolves the fixture value by default (deterministic seed)", () => {
    expect(canonicalPriceUsd("ETH")).toBe(PRICE_FIXTURE.ETH)
    expect(canonicalPriceUsd("weth")).toBe(PRICE_FIXTURE.WETH)
  })

  it("returns undefined (unavailable) for a symbol neither the oracle nor the fixture covers", () => {
    expect(canonicalPriceUsd("NOTATOKEN")).toBeUndefined()
    expect(canonicalPriceUsd("")).toBeUndefined()
  })

  it("overlays live oracle prices on top of the fixture (majors move, uncovered stay)", () => {
    setCanonicalPrices({ eth: 2500, usdt: 0.999 })
    expect(canonicalPriceUsd("ETH")).toBe(2500)
    expect(canonicalPriceUsd("USDT")).toBe(0.999)
    // A token the live payload omitted still resolves from the fixture.
    expect(canonicalPriceUsd("WBTC")).toBe(PRICE_FIXTURE.WBTC)
  })

  it("drops non-finite/non-positive live quotes rather than storing them", () => {
    setCanonicalPrices({ eth: 0, usdc: Number.NaN, dai: -1 })
    // Bad quotes ignored → fixture values remain.
    expect(canonicalPriceUsd("ETH")).toBe(PRICE_FIXTURE.ETH)
    expect(canonicalPriceUsd("USDC")).toBe(PRICE_FIXTURE.USDC)
  })

  it("engine helper reflects the live overlay and defaults unknown symbols to $1", () => {
    setCanonicalPrices({ eth: 2500 })
    expect(sandboxBaselinePriceUsd("ETH")).toBe(2500)
    expect(sandboxBaselinePriceUsd("NOTATOKEN")).toBe(1)
  })

  it("reset restores the deterministic fixture", () => {
    setCanonicalPrices({ eth: 9999 })
    resetCanonicalPrices()
    expect(canonicalPriceUsd("ETH")).toBe(PRICE_FIXTURE.ETH)
  })
})
