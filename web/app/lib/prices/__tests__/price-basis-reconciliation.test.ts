import { describe, expect, it } from "vitest"
import { canonicalPriceUsd } from "@/app/lib/prices/canonical"
import { sandboxBaselinePriceUsd } from "@/app/lib/prices/sandbox-baseline-prices"
import { formatTokenPrice } from "@/app/lib/prices/format"
import { injectBaselinePrice } from "@/app/lib/detail-page/live-detail-helpers"

/**
 * Reconciliation guard for the single canonical price basis (F1/F2).
 *
 * The bug we removed: the borrow list read the live oracle while the detail "Price" tile read
 * the baseline, so the same token showed two USD prices one click apart. This locks the
 * invariant that every DISPLAY surface resolves a token to the ONE canonical price, so the
 * two-source split can never silently return.
 */

const SHARED_SYMBOLS = ["ETH", "WETH", "USDC", "USDT", "WBTC", "AAVE", "LINK"]

describe("single canonical price basis reconciliation", () => {
  it("the detail 'Price' tile equals the canonical price shown on the borrow list", () => {
    for (const symbol of SHARED_SYMBOLS) {
      // Borrow list subtitle renders formatTokenPrice(canonicalPriceUsd(symbol)).
      const listValue = formatTokenPrice(canonicalPriceUsd(symbol)!)
      // Detail tile renders injectBaselinePrice, which must resolve to the same canonical price.
      const tile = injectBaselinePrice([{ id: "price", value: "STALE" }], symbol)
      expect(tile[0].value).toBe(listValue)
    }
  })

  it("the tile's baseline accessor and the display's canonical accessor are the same number", () => {
    // sandboxBaselinePriceUsd (tile/engine, defaults to 1) and canonicalPriceUsd (display, strict)
    // must agree for every symbol the snapshot covers — one basis, two ergonomic accessors.
    for (const symbol of SHARED_SYMBOLS) {
      expect(canonicalPriceUsd(symbol)).toBe(sandboxBaselinePriceUsd(symbol))
    }
  })
})
