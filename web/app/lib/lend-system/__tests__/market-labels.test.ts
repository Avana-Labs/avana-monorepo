import { describe, expect, it } from "vitest"
import {
  formatLendMarketDropdownSublabel,
  formatLendMarketValueLabel,
  getLendMarketMeta,
} from "@/app/lib/lend-system/market-labels"

describe("lend market labels", () => {
  it("maps stablecoin assets to the Stable hub bucket", () => {
    expect(getLendMarketMeta("USDC")).toEqual({
      hubBucket: "Stable",
      marketTier: "Core",
      issuerHub: "Circle",
    })
  })

  it("maps volatile assets to the Volatile hub bucket", () => {
    expect(getLendMarketMeta("ETH").hubBucket).toBe("Volatile")
    expect(getLendMarketMeta("ETH").marketTier).toBe("Native")
    expect(getLendMarketMeta("cbBTC").marketTier).toBe("Wrapped")
  })

  it("formats dropdown and position labels with hub and tier", () => {
    expect(formatLendMarketDropdownSublabel("USDC")).toBe("Stable · Core")
    expect(formatLendMarketValueLabel("ETH")).toBe("ETH · Volatile · Native")
  })
})
