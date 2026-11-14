import { describe, expect, it } from "vitest"
import { getAssetDetail, getPoolDetail, listAllAssetDetails, listAllPoolDetails } from "@/app/lib/borrow-detail"
import {
  isPlaceholderHeroContractAddress,
  isSafeHeroLink,
  resolveHeroContractLabel,
} from "@/app/borrow/_detail/lib/hero-chart-feeds"

describe("borrow detail contract", () => {
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
})
