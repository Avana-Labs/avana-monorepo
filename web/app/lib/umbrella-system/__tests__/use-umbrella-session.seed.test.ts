import { describe, expect, it } from "vitest"
import { buildDefaultUmbrellaState, UMBRELLA_MARKET_ORDER } from "@/app/lib/umbrella-system/use-umbrella-session"

describe("buildDefaultUmbrellaState", () => {
  it("keeps every seeded position's valueUsd consistent with amount × market priceUsd", () => {
    const state = buildDefaultUmbrellaState("wallet-seed")
    for (const marketId of UMBRELLA_MARKET_ORDER) {
      const position = state.positions[marketId]
      const market = state.markets[marketId]
      // The session recomputes displayed value as amount × priceUsd after every
      // action, so the seed literals must already satisfy that invariant — a
      // mismatch (e.g. a value derived from a stale price) shows a wrong figure
      // until the first action rewrites it.
      expect(position.valueUsd).toBeCloseTo(position.amount * market.priceUsd, 2)
    }
  })

  it("seeds WETH at the canonical 1934 oracle price", () => {
    const state = buildDefaultUmbrellaState("wallet-seed")
    expect(state.markets.weth.priceUsd).toBe(1934)
    expect(state.positions.weth.valueUsd).toBeCloseTo(3.125 * 1934, 2)
  })
})
