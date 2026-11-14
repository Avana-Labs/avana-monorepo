import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

describe("detail heroes prefer Convex heroFeed on primary tab", () => {
  it("AssetHero prefers detail.heroFeed for Supplied before mock series", () => {
    const source = readFileSync(resolve(__dirname, "../AssetHero.tsx"), "utf8")
    const preferIdx = source.indexOf(
      "detail.heroFeed ??\n      buildFeedFromRangeSeries(detail.heroMetric.series.supply",
    )
    expect(preferIdx).toBeGreaterThan(-1)
  })

  it("Multiply MarketHero prefers detail.heroFeed for Supplied before mock series", () => {
    const source = readFileSync(
      resolve(__dirname, "../../../../multiply/_detail/market-sections/MarketHero.tsx"),
      "utf8",
    )
    const preferIdx = source.indexOf("detail.heroFeed ??\n      buildFeedFromSeries(detail.supplyBorrow.supplied")
    expect(preferIdx).toBeGreaterThan(-1)
  })
})
