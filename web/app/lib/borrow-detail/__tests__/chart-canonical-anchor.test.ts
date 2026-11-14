import { describe, expect, it } from "vitest"

import { buildAssetDetail, resolveAsset } from "@/app/lib/borrow-detail/asset.mock"
import { injectBaselinePrice } from "@/app/lib/detail-page/live-detail-helpers"
import { canonicalPriceUsd } from "@/app/lib/prices/canonical"
import { formatTokenPrice } from "@/app/lib/prices/format"
import type { AssetDetail, TimeRangeId } from "@/app/lib/borrow-detail/types"

/**
 * Pricing commit C4 — chart anchor + tile alignment.
 *
 * The detail-page price CHART (heroMetric.series.price) and the price TILE (heroMetric.valueLabel /
 * the "Price" quick-stat) must agree with the canonical basis (canonicalPriceUsd), and the mock tile
 * must show the same number the Convex tile shows (injectBaselinePrice reads the same baseline).
 */

const ALL_RANGES: TimeRangeId[] = ["1D", "1W", "1M", "3M", "1Y", "ALL"]

function detailFor(id: string): AssetDetail {
  const asset = resolveAsset(id)
  if (!asset) throw new Error(`fixture asset not resolvable: ${id}`)
  return buildAssetDetail(asset)
}

function terminalOf(detail: AssetDetail, range: TimeRangeId): number {
  const points = detail.heroMetric.series.price[range].points
  return points[points.length - 1].v
}

describe("price chart canonical anchor (C4)", () => {
  it("anchors the ETH price series terminal to the canonical $1,934 (not the stale $1,791.81)", () => {
    const detail = detailFor("curve-correlated:eth") // baseAssetId "eth" → curated series path
    const canonical = canonicalPriceUsd("ETH")
    expect(canonical).toBe(1934)

    for (const range of ALL_RANGES) {
      const terminal = terminalOf(detail, range)
      expect(terminal).toBe(canonical)
      expect(terminal).not.toBe(1791.81) // the old stale terminal
    }
  })

  it("anchors the WBTC and USDC price series terminals to canonical (synthetic path)", () => {
    const wbtc = detailFor("uni-v2:wbtc")
    for (const range of ALL_RANGES) {
      expect(terminalOf(wbtc, range)).toBe(canonicalPriceUsd("WBTC"))
    }
    expect(canonicalPriceUsd("WBTC")).toBe(65000)

    const usdc = detailFor("uni-v3-stable:usdc")
    for (const range of ALL_RANGES) {
      expect(terminalOf(usdc, range)).toBe(canonicalPriceUsd("USDC"))
    }
    expect(canonicalPriceUsd("USDC")).toBe(1)
  })

  it("makes the mock ETH tile equal the Convex ETH tile equal the canonical price", () => {
    const detail = detailFor("curve-correlated:eth")
    const expected = formatTokenPrice(canonicalPriceUsd("ETH")!) // "$1,934.00"

    // Mock tile: hero metric label + the "Price" quick stat as built by asset.mock.
    const mockPriceStat = detail.quickStats.find((stat) => stat.id === "price")
    expect(mockPriceStat?.value).toBe(expected)
    expect(detail.heroMetric.valueLabel).toBe(expected)

    // Convex tile: injectBaselinePrice pins the "Price" stat to the same baseline (keyed on the
    // base asset symbol, matching convex-detail.ts's injectBaselinePrice(..., record.baseAssetId)).
    const convexPrice = injectBaselinePrice(detail.quickStats, "eth").find((stat) => stat.id === "price")
    expect(convexPrice?.value).toBe(expected)

    // mock tile === convex tile
    expect(mockPriceStat?.value).toBe(convexPrice?.value)
  })
})
