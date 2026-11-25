import { describe, expect, it } from "vitest"
import { lendSparklinePath, withFeaturedSparklines } from "../read-model"
import type { LendPageData } from "@/app/lib/data/providers/lend/types"

describe("lendSparklinePath", () => {
  it("spreads the points over the width with the highest APY on top", () => {
    expect(lendSparklinePath([1, 3, 2])).toBe("M0,60L198,0L396,30")
  })

  it("draws a flat line for a constant series and nothing for fewer than two points", () => {
    expect(lendSparklinePath([0, 0])).toBe("M0,0L396,0")
    expect(lendSparklinePath([4])).toBe("")
    expect(lendSparklinePath([])).toBe("")
  })
})

describe("withFeaturedSparklines", () => {
  const asset = { id: "ethereum-gho", symbol: "GHO", displayName: "Gho Token", eyebrow: "Stablecoin", apy: 3, tone: "green" as const, iconUrl: "" }
  const page = {
    featuredAssets: { "ethereum-gho": asset, "base-usdc": { ...asset, id: "base-usdc" } },
  } as unknown as LendPageData

  it("adds each card's path and values, and leaves a card without a series as it was", () => {
    const next = withFeaturedSparklines(page, { "ethereum-gho": [2, 3] })
    expect(next.featuredAssets["ethereum-gho"]).toMatchObject({ path: "M0,60L396,0", values: [2, 3] })
    expect(next.featuredAssets["base-usdc"]).toEqual({ ...asset, id: "base-usdc" })
  })
})
