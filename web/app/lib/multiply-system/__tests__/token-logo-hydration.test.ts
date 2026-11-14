import { describe, expect, it } from "vitest"
import { buildMultiplyPageData, type MultiplyTokenParameterRow } from "@/app/lib/multiply-system/read-model"

/**
 * The client hydrator passes Convex multiplyTokenParameters rows into
 * buildMultiplyPageData. The deployed Convex seed still carries stale `.svg`
 * iconUrl values (the public asset-icons were swapped to `.png`), so trusting
 * row.iconUrl 404s the Borrowable column. The token-logo map must resolve from
 * the LOCAL png resolver instead — the same source the collateral column uses.
 */
function convexRow(overrides: Partial<MultiplyTokenParameterRow>): MultiplyTokenParameterRow {
  return {
    symbol: "USDT",
    supplyApyPct: 3.2,
    borrowAprPct: 4.1,
    availableUsd: 1_000_000,
    collateralFactorPct: 80,
    liquidationThresholdPct: 85,
    iconUrl: "/asset-icons/usdt.svg",
    ...overrides,
  }
}

describe("buildMultiplyPageData token-logo hydration from Convex", () => {
  it("resolves borrowable token icons to local .png even when Convex iconUrl is a stale .svg", () => {
    const convexTokens: MultiplyTokenParameterRow[] = [
      convexRow({ symbol: "USDT", iconUrl: "/asset-icons/usdt.svg" }),
      convexRow({ symbol: "GHO", iconUrl: "/asset-icons/gho.svg" }),
      convexRow({ symbol: "ETH", iconUrl: "/asset-icons/eth.svg" }),
      convexRow({ symbol: "WBTC", iconUrl: "/asset-icons/wbtc.svg" }),
    ]

    const page = buildMultiplyPageData("wallet-1", undefined, convexTokens)

    expect(page.tokenLogos.USDT).toBe("/asset-icons/usdt.png")
    expect(page.tokenLogos.GHO).toBe("/asset-icons/gho.png")
    expect(page.tokenLogos.ETH).toBe("/asset-icons/eth.png")
    expect(page.tokenLogos.WBTC).toBe("/asset-icons/wbtc.png")

    // No entry may leak a `.svg` path from the stale Convex seed.
    for (const value of Object.values(page.tokenLogos)) {
      expect(value.endsWith(".svg")).toBe(false)
    }
  })

  it("resolves a slug-aliased symbol through the local resolver", () => {
    // crvUSD maps through the CRVUSD -> "crvusd" slug alias in local-asset-icons.
    const page = buildMultiplyPageData("wallet-1", undefined, [
      convexRow({ symbol: "crvUSD", iconUrl: "/asset-icons/crvusd.svg" }),
    ])

    expect(page.tokenLogos.crvUSD).toBe("/asset-icons/crvusd.png")
  })
})
