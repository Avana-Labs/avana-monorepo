import { describe, expect, it } from "vitest"
import {
  getSpokeBorrowable,
  listBorrowMarkets,
  listBorrowSpokes,
  listSpokeBorrowables,
} from "@/app/lib/borrow-system/registry"

describe("borrow system registry", () => {
  it("builds the canonical spoke-bound borrow catalog counts", () => {
    expect(listBorrowSpokes()).toHaveLength(17)
    expect(listBorrowMarkets()).toHaveLength(80)
    expect(listSpokeBorrowables()).toHaveLength(71)
  })

  it("binds every collateral market and borrowable to exactly one spoke", () => {
    const spokes = listBorrowSpokes()
    const markets = listBorrowMarkets()
    const borrowables = listSpokeBorrowables()

    expect(new Set(markets.map((market) => market.id)).size).toBe(80)
    expect(new Set(borrowables.map((borrowable) => borrowable.id)).size).toBe(71)

    for (const market of markets) {
      const owners = spokes.filter((spoke) => spoke.collateralMarketIds.includes(market.id))
      expect(owners).toHaveLength(1)
      expect(owners[0]?.id).toBe(market.spokeId)
    }

    for (const borrowable of borrowables) {
      const owners = spokes.filter((spoke) => spoke.borrowableIds.includes(borrowable.id))
      expect(owners).toHaveLength(1)
      expect(owners[0]?.id).toBe(borrowable.spokeId)
    }
  })

  it("treats the same base token on different spokes as different borrowable products", () => {
    const uniUsdc = getSpokeBorrowable("uni-v3-stable:usdc")
    const curveUsdc = getSpokeBorrowable("curve-stable:usdc")

    expect(uniUsdc?.baseAssetId).toBe("usdc")
    expect(curveUsdc?.baseAssetId).toBe("usdc")
    expect(uniUsdc?.id).not.toBe(curveUsdc?.id)
    expect(uniUsdc?.spokeId).toBe("uni-v3-stable")
    expect(curveUsdc?.spokeId).toBe("curve-stable")
    expect(uniUsdc?.contextLabel).not.toBe(curveUsdc?.contextLabel)
    expect(uniUsdc?.borrowApr).not.toBe(curveUsdc?.borrowApr)
  })
})
