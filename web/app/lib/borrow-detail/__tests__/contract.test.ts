import { describe, expect, it } from "vitest"
import { getAssetDetail, getPoolDetail, listAllAssetDetails, listAllPoolDetails } from "@/app/lib/borrow-detail"
import {
  isPlaceholderHeroContractAddress,
  isSafeHeroLink,
  resolveHeroContractLabel,
} from "@/app/borrow/_detail/lib/hero-chart-feeds"

describe("borrow detail contract", () => {
  it("uses the lend headline set for borrow pool key statistics", () => {
    const detail = getPoolDetail("uni-v3-bluechip-weth-usdc")!
    expect(detail.quickStats.map((stat) => stat.id)).toEqual([
      "price",
      "available",
      "supplyApy",
      "rewardsApy",
      "borrowApy",
      "reserveFactor",
    ])
    expect(detail.about.governanceParameters?.parameters[0]?.label).toBe("Collateral factor")
  })

  it("always exposes a lend-style hero contract address for borrow pools", () => {
    const curated = getPoolDetail("uni-v3-bluechip-weth-usdc")!
    const v2 = getPoolDetail("uni-v2-weth-usdt")!
    expect(curated.hero.explorerUrl).toMatch(/0x[a-fA-F0-9]{40}/)
    expect(v2.hero.explorerUrl).toMatch(/0x[a-fA-F0-9]{40}/)
    expect(resolveHeroContractLabel(curated.id, curated.hero.explorerUrl)).toMatch(
      /^0x[a-fA-F0-9]{4}\.\.\.[a-fA-F0-9]{4}$/,
    )
    expect(resolveHeroContractLabel(v2.id, v2.hero.explorerUrl)).toMatch(/^0x[a-fA-F0-9]{4}\.\.\.[a-fA-F0-9]{4}$/)
  })

  it("flags repeated-hex synthetic contract addresses as placeholders", () => {
    // The seed builds addresses as an 8-hex chunk repeated five times.
    expect(isPlaceholderHeroContractAddress("0x730DF60E730DF60E730DF60E730DF60E730DF60E")).toBe(true)
    // A real, non-repeating address is not a placeholder.
    expect(isPlaceholderHeroContractAddress("0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640")).toBe(false)
    expect(isPlaceholderHeroContractAddress(undefined)).toBe(false)
    expect(isPlaceholderHeroContractAddress("not-an-address")).toBe(false)
  })

  it("treats explorer URLs wrapping a placeholder address as unsafe to link", () => {
    expect(isSafeHeroLink("https://etherscan.io/address/0x730DF60E730DF60E730DF60E730DF60E730DF60E")).toBe(false)
    expect(isSafeHeroLink("https://etherscan.io/address/0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640")).toBe(true)
    // Real project sites (no embedded address) stay linkable.
    expect(isSafeHeroLink("https://app.uniswap.org/explore")).toBe(true)
    expect(isSafeHeroLink(undefined)).toBe(false)
  })

  it("resolves canonical and home-alias pool ids from the canonical borrow system", () => {
    expect(getPoolDetail("uni-v3-bluechip-weth-usdc")?.hero.name).toBe("WETH / USDC")
    expect(getPoolDetail("eth-usdc")?.hero.name).toBe("WETH / USDC")
    expect(listAllPoolDetails().length).toBeGreaterThan(5)
  })

  it("resolves spoke-bound borrowable detail pages as distinct product records", () => {
    const uniUsdc = getAssetDetail("uni-v3-stable:usdc")
    const curveUsdc = getAssetDetail("curve-stable:usdc")

    expect(uniUsdc?.hero.symbol).toBe("USDC")
    expect(curveUsdc?.hero.symbol).toBe("USDC")
    expect(uniUsdc?.id).toBe("uni-v3-stable:usdc")
    expect(curveUsdc?.id).toBe("curve-stable:usdc")
    expect(uniUsdc?.hero.subtitle).not.toBe(curveUsdc?.hero.subtitle)
    expect(uniUsdc?.row.id).not.toBe(curveUsdc?.row.id)
    expect(listAllAssetDetails().length).toBe(71)
  })

  it("resolves URL-encoded spoke asset route params", () => {
    expect(getAssetDetail("uni-v2%3Adai")?.hero.symbol).toBe("DAI")
    expect(getAssetDetail("uni-v2%3Adai")?.id).toBe("uni-v2:dai")
  })

  it("uses the lend headline set for borrowable asset key statistics", () => {
    const detail = getAssetDetail("uni-v3-stable:usdc")!
    expect(detail.quickStats.map((stat) => stat.id)).toEqual([
      "price",
      "available",
      "supplyApy",
      "rewardsApy",
      "borrowApy",
      "reserveFactor",
    ])
    expect(detail.quickStats.find((stat) => stat.id === "supplied")).toBeUndefined()
    expect(detail.quickStats.find((stat) => stat.id === "dexLiquidity")).toBeUndefined()
    expect(detail.quickStats.find((stat) => stat.id === "utilization")).toBeUndefined()
  })

  it("fills eight Morpho-aligned risk parameters on every borrow pool", () => {
    const labels = [
      "Collateral factor",
      "Collateral risk",
      "Deposit capacity",
      "Liquidation penalty",
      "Borrow capacity",
      "Target health factor",
      "Liquidation threshold",
      "Oracle source",
    ]
    for (const detail of listAllPoolDetails()) {
      expect(detail.about.governanceParameters?.parameters.map((parameter) => parameter.label)).toEqual(labels)
      expect(detail.about.governanceParameters?.parameters.every((parameter) => parameter.value.length > 0)).toBe(true)
    }
  })

  it("uses lend-style risk parameters instead of the interest-rate model", () => {
    const detail = getAssetDetail("uni-v3-stable:usdc")!
    expect(detail.about.governanceParameters?.parameters.map((parameter) => parameter.label)).toEqual([
      "Collateral factor",
      "Collateral risk",
      "Deposit capacity",
      "Liquidation penalty",
      "Borrow capacity",
      "Target health factor",
      "Liquidation threshold",
      "Oracle source",
    ])
    expect(detail.about.governanceParameters?.changelog.length).toBeGreaterThan(0)
    // Contract-address stats moved out of the mock builder. They're injected at
    // Convex overlay time (getAssetDetailFromConvex + api.contractAddresses.listAssetAddresses),
    // so the mock detail starts with an empty stats array; the overlay appends the rows.
    expect(detail.about.stats).toEqual([])
  })
})
