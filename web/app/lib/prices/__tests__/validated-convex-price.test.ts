import { describe, expect, it } from "vitest"
import {
  CONVEX_PRICE_INVALID_AFTER_MS,
  isUsableConvexPrice,
  validatedConvexPriceMap,
} from "@/app/lib/prices/validated-convex-price"

const now = 2_000_000_000_000

describe("validated Convex prices", () => {
  it("accepts current positive high-confidence rows", () => {
    expect(
      isUsableConvexPrice(
        {
          symbol: "AAVE",
          priceUsd: 126,
          confidence: 0.99,
          status: "fresh",
          updatedAt: now - 60_000,
        },
        now,
      ),
    ).toBe(true)
  })

  it("rejects invalid, expired, low-confidence, and non-positive rows", () => {
    const base = { symbol: "USDC", priceUsd: 1, confidence: 0.99, status: "fresh" as const, updatedAt: now }
    expect(isUsableConvexPrice({ ...base, status: "invalid" }, now)).toBe(false)
    expect(isUsableConvexPrice({ ...base, updatedAt: now - CONVEX_PRICE_INVALID_AFTER_MS }, now)).toBe(false)
    expect(isUsableConvexPrice({ ...base, confidence: 0.4 }, now)).toBe(false)
    expect(isUsableConvexPrice({ ...base, priceUsd: 0 }, now)).toBe(false)
  })

  it("builds an overlay only from usable Convex rows", () => {
    expect(
      validatedConvexPriceMap(
        [
          { symbol: "AAVE", priceUsd: 126, status: "fresh", updatedAt: now },
          { symbol: "USDC", priceUsd: 0.3, status: "fresh", updatedAt: now },
          { symbol: "WETH", priceUsd: 1900, status: "fresh", updatedAt: now - CONVEX_PRICE_INVALID_AFTER_MS },
        ],
        now,
      ),
    ).toEqual({ aave: 126 })
  })
})
