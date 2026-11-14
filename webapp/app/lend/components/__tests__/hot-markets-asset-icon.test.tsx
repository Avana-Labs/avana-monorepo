import { render } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { AssetIcon } from "../hot-markets"
import type { LendPageData } from "@/app/lib/data/providers/lend"

type FeaturedAsset = LendPageData["featuredAssets"][keyof LendPageData["featuredAssets"]]

const asset = {
  id: "usdc",
  symbol: "USDC",
  displayName: "USD Coin",
  eyebrow: "Bluechip",
  apy: 3.46,
  tone: "blue",
  iconUrl: "/icons/usdc.svg",
  path: "M0,0",
} as unknown as FeaturedAsset

describe("HotMarkets AssetIcon", () => {
  it("eager-loads the featured asset icon for LCP instead of lazy-loading it", () => {
    const { getByAltText } = render(<AssetIcon asset={asset} />)
    const img = getByAltText("USDC logo")

    // next/image renders loading="lazy" by default; with `priority` it must not.
    expect(img.getAttribute("loading")).not.toBe("lazy")
  })
})
