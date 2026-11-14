import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { TokenPricesContext, useCanonicalPriceFor } from "@/app/lib/prices/token-prices-context"
import { priceKey } from "@/app/lib/prices/format"

/**
 * The lend list / borrow table / action pages read the per-token price via
 * `useCanonicalPriceFor`. The bug it fixes: they used the non-reactive `canonicalPriceUsd`
 * module read, captured once and never updated when the live overlay arrived, so every price
 * stayed pinned to the fixture (AAVE $105, ETH $1934). The reactive hook must (a) reflect the
 * live context value and (b) fall back to the deterministic fixture when a symbol is unpriced.
 */
function Probe({ symbol }: { symbol: string }) {
  const priceFor = useCanonicalPriceFor()
  const price = priceFor(symbol)
  return <span data-testid="p">{price === undefined ? "unpriced" : String(price)}</span>
}

function renderWith(map: Record<string, number>, symbol: string) {
  cleanup() // each call is an independent render; drop the previous tree first
  render(
    <TokenPricesContext.Provider value={map}>
      <Probe symbol={symbol} />
    </TokenPricesContext.Provider>,
  )
  return screen.getByTestId("p").textContent
}

afterEach(cleanup)

describe("useCanonicalPriceFor", () => {
  it("returns the live oracle price from context (keyed case-insensitively)", () => {
    // Context is keyed by priceKey (lowercased symbol), like the live provider builds it.
    expect(renderWith({ [priceKey("AAVE")]: 88.77, [priceKey("ETH")]: 1902.05 }, "AAVE")).toBe("88.77")
    expect(renderWith({ [priceKey("ETH")]: 1902.05 }, "eth")).toBe("1902.05")
  })

  it("falls back to the deterministic PRICE_FIXTURE when the live price is absent", () => {
    // Empty live context (SSR / pre-hydration): a known token still resolves to the fixture
    // (AAVE 105, ETH 1934) rather than its bare symbol — no hydration mismatch, always a price.
    expect(renderWith({}, "AAVE")).toBe("105")
    expect(renderWith({}, "ETH")).toBe("1934")
  })

  it("prefers the live price over the fixture once it arrives", () => {
    // Simulates the overlay landing: ETH live 1902.05 must win over the fixture 1934.
    expect(renderWith({ [priceKey("ETH")]: 1902.05 }, "ETH")).toBe("1902.05")
  })

  it("returns undefined for a symbol neither the oracle nor the fixture covers", () => {
    expect(renderWith({}, "NOT_A_TOKEN")).toBe("unpriced")
  })
})
