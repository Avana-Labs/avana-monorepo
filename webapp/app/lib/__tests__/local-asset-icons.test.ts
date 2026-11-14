import { describe, expect, it } from "vitest"
import { getLocalAssetIcon, LOCAL_ASSET_ICON_FALLBACK } from "@/app/lib/local-asset-icons"

describe("getLocalAssetIcon", () => {
  it("resolves the LINK token symbol to the Chainlink icon, not the placeholder (#42)", () => {
    expect(getLocalAssetIcon("LINK")).toBe("/asset-icons/chainlink.png")
    expect(getLocalAssetIcon("link")).toBe("/asset-icons/chainlink.png")
  })

  it("falls back to the neutral placeholder for an unmapped symbol", () => {
    expect(getLocalAssetIcon("ZZZUNKNOWN")).toBe(LOCAL_ASSET_ICON_FALLBACK)
  })
})
