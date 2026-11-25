import { describe, expect, it } from "vitest"
import {
  borrowAssetDetailPath,
  borrowMarketDetailPath,
  normalizeBorrowAssetRouteId,
  normalizeBorrowMarketRouteId,
} from "@/app/lib/borrow-routes"

describe("borrow asset routes", () => {
  it("decodes encoded spoke asset ids from dynamic route params", () => {
    expect(normalizeBorrowAssetRouteId("uni-v2%3Adai")).toBe("uni-v2:dai")
    expect(normalizeBorrowAssetRouteId("uni-v2:dai")).toBe("uni-v2:dai")
  })

  it("builds encoded detail paths for spoke asset ids", () => {
    expect(borrowAssetDetailPath("uni-v2:dai")).toBe("/borrow/assets/uni-v2%3Adai")
  })
})

describe("borrow market routes", () => {
  it("decodes encoded market ids from dynamic route params", () => {
    expect(normalizeBorrowMarketRouteId("aero-basic-volatile-well-weth")).toBe("aero-basic-volatile-well-weth")
  })

  it("builds market detail paths", () => {
    expect(borrowMarketDetailPath("aero-basic-volatile-well-weth")).toBe(
      "/borrow/markets/aero-basic-volatile-well-weth",
    )
  })
})
