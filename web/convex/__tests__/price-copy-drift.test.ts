import { describe, expect, it } from "vitest"
import { PRICE_FIXTURE } from "@/app/lib/prices/price-fixture"
import { SANDBOX_TOKEN_PRICE_USD } from "../sandbox/onboarding"
import { UMBRELLA_ONBOARDING_TOKEN_PRICES } from "../sandbox/umbrella"

/**
 * Convex functions can't import app/ modules, so the server-side price fallbacks are hand-copied
 * from the app's PRICE_FIXTURE. Those copies have drifted before (weth was 1934 in onboarding vs
 * 2240 in umbrella). This test turns "keep in sync by hand" into an enforced invariant: any copy
 * that diverges from the single fixture fails CI. (The live oracle is preferred at runtime; these
 * are only the cold-cache fallback, so they must at least agree with the deterministic seed.)
 */
describe("Convex price copies must not drift from the app fixture (C19)", () => {
  it("onboarding SANDBOX_TOKEN_PRICE_USD matches PRICE_FIXTURE", () => {
    for (const [symbol, price] of Object.entries(SANDBOX_TOKEN_PRICE_USD)) {
      const fixturePrice = PRICE_FIXTURE[symbol.toUpperCase()]
      expect(fixturePrice, `${symbol} is missing from PRICE_FIXTURE`).toBeDefined()
      expect(price, `${symbol} drifted from the fixture`).toBe(fixturePrice)
    }
  })

  it("umbrella UMBRELLA_ONBOARDING_TOKEN_PRICES matches PRICE_FIXTURE", () => {
    for (const [symbol, price] of Object.entries(UMBRELLA_ONBOARDING_TOKEN_PRICES)) {
      expect(price, `${symbol} drifted from the fixture`).toBe(PRICE_FIXTURE[symbol.toUpperCase()])
    }
  })
})
