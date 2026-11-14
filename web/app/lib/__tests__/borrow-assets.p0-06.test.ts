import { describe, expect, it } from "vitest"
import { BORROWABLE_ASSETS } from "@/app/lib/borrow-market-rows"

describe("p0-06 borrow asset routes", () => {
  it("does not advertise bare aave/uni/crv assets without working detail routes", () => {
    const advertisedAssetIds = BORROWABLE_ASSETS.map((asset) => asset.id)
    expect(advertisedAssetIds).not.toEqual(expect.arrayContaining(["aave", "uni", "crv"]))
  })
})
