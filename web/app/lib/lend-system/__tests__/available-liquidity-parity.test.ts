import { describe, expect, it } from "vitest"
import { LEND_MARKET_CATALOG } from "@/app/lib/lend-system/catalog"

/**
 * #19 — the list's "Available" and the detail page's "Available Liquidity" must
 * describe the same quantity: deposits · (1 − utilization). Previously the list
 * stored the catalog's borrowed figure as availableLiquidity for stablecoins, so
 * it showed borrowed (deposits · util) while the detail page showed the real
 * available. Both now derive from the market's own utilization.
 */
describe("lend market available liquidity", () => {
  it("available liquidity equals supplied · (1 − utilization) for every market", () => {
    for (const market of LEND_MARKET_CATALOG) {
      const expected = market.totalSupplied * (1 - market.utilization)
      expect(market.availableLiquidity).toBeCloseTo(expected, 4)
    }
  })

  it("USDC reports available as the unborrowed share, not the borrowed share", () => {
    const usdc = LEND_MARKET_CATALOG.find((m) => m.asset.symbol.toUpperCase() === "USDC")
    expect(usdc).toBeDefined()
    if (!usdc) return
    // 32% utilized → ~68% available, not ~32%.
    expect(usdc.availableLiquidity).toBeGreaterThan(usdc.totalBorrowed)
    expect(usdc.availableLiquidity / usdc.totalSupplied).toBeCloseTo(1 - usdc.utilization, 4)
  })
})
