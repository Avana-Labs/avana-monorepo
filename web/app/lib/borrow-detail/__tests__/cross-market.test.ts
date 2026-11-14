import { describe, expect, it } from "vitest"
import { BORROW_POOL_CATALOG } from "@/app/lib/borrow-sim"
import { listSpokeBorrowables } from "@/app/lib/borrow-system/registry"
import { filterPoolsForSpokeAsset, resolveBorrowablesForPool, resolveCollateralForAsset } from "../cross-market"

describe("cross-market reference lists", () => {
  it("resolves spoke-matched borrowables for every collateral market", () => {
    for (const pool of BORROW_POOL_CATALOG) {
      const assets = resolveBorrowablesForPool(pool)
      expect(assets.length).toBeGreaterThan(0)
      expect(assets.every((asset) => asset.href.includes("/borrow/assets/"))).toBe(true)
      expect(assets.every((asset) => asset.apy > 0)).toBe(true)
      // Same spoke only — Uni v2 LPs never list Curve/Balancer borrowables.
      const spokeAssets = listSpokeBorrowables().filter((asset) => asset.spokeId === pool.spoke)
      expect(assets.map((asset) => asset.id).sort()).toEqual(spokeAssets.map((asset) => asset.id).sort())
    }
  })

  it("resolves collateral markets for every borrowable asset with that asset's LTV", () => {
    for (const asset of listSpokeBorrowables()) {
      const markets = resolveCollateralForAsset(asset)
      expect(markets.length).toBeGreaterThan(0)
      expect(markets.every((market) => asset.marketIds.includes(market.id))).toBe(true)
      expect(markets.every((market) => market.href.includes("/borrow/markets/"))).toBe(true)
      expect(markets.every((market) => market.collateralFactorPct > 0)).toBe(true)
    }
  })

  it("keeps Balancer GHO collateral spoke-scoped (no Uniswap v3 Stable pools)", () => {
    const asset = listSpokeBorrowables().find((entry) => entry.id === "bal-stable:gho")
    expect(asset).toBeTruthy()
    const markets = resolveCollateralForAsset(asset!)
    expect(markets.length).toBeGreaterThan(0)
    expect(markets.every((market) => market.id.startsWith("bal-stable"))).toBe(true)
    expect(
      markets.some((market) => market.id.includes("uni-v3") || market.venue.toLowerCase().includes("uniswap")),
    ).toBe(false)

    const leaked = filterPoolsForSpokeAsset(
      "bal-stable:gho",
      BORROW_POOL_CATALOG.map((pool) => ({ id: pool.id, venue: pool.venue })),
    )
    expect(leaked.every((pool) => pool.id.startsWith("bal-stable"))).toBe(true)
    expect(leaked.some((pool) => pool.id.includes("uni-v3-stable"))).toBe(false)
  })

  it("keeps market borrowables spoke-scoped for Balancer Stable pools", () => {
    const balPools = BORROW_POOL_CATALOG.filter((pool) => pool.spoke === "bal-stable")
    expect(balPools.length).toBeGreaterThan(0)
    for (const pool of balPools) {
      const assets = resolveBorrowablesForPool(pool)
      expect(assets.every((asset) => asset.id.startsWith("bal-stable:"))).toBe(true)
      expect(assets.some((asset) => asset.id.startsWith("uni-v3-"))).toBe(false)
    }
  })
})
