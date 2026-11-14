import { describe, expect, it } from "vitest"
import { isPlaceholderHeroContractAddress, isSafeHeroLink } from "@/app/borrow/_detail/lib/hero-chart-feeds"
import { heroContractFromRows } from "@/app/lib/detail-page/hero-contract"

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

  it("allows only https hero links", () => {
    expect(isSafeHeroLink("http://example.org")).toBe(false)
    expect(isSafeHeroLink("javascript:alert(1)")).toBe(false)
    expect(isSafeHeroLink("data:text/html,<b>x</b>")).toBe(false)
    expect(isSafeHeroLink("//evil.example")).toBe(false)
  })
})

describe("heroContractFromRows", () => {
  const pool = "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640"
  const checksummed = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640"
  const row = (overrides: Partial<{ address: string; label: string; href: string; isSynthetic: boolean }> = {}) => ({
    address: pool,
    label: "Pool",
    href: `https://etherscan.io/address/${pool}`,
    isSynthetic: false,
    ...overrides,
  })

  it("returns the checksummed address and its explorer link", () => {
    expect(
      heroContractFromRows(
        [row({ label: "Hub", address: "0x1111111111111111111111111111111111111111" }), row()],
        "Pool",
      ),
    ).toEqual({
      address: checksummed,
      explorerHref: `https://etherscan.io/address/${checksummed}`,
    })
  })

  it("never fabricates an address", () => {
    expect(heroContractFromRows([], "Pool")).toBeNull()
    expect(heroContractFromRows(undefined, "Token")).toBeNull()
    expect(heroContractFromRows([row()], "Token")).toBeNull()
    expect(heroContractFromRows([row({ isSynthetic: true })], "Pool")).toBeNull()
    expect(heroContractFromRows([row({ address: "0x1234" })], "Pool")).toBeNull()
    expect(heroContractFromRows([row({ address: "0x0000000000000000000000000000000000000000" })], "Pool")).toBeNull()
  })

  it("drops an explorer link that is not https or names another address", () => {
    expect(heroContractFromRows([row({ href: "" })], "Pool")?.explorerHref).toBeNull()
    expect(
      heroContractFromRows([row({ href: `http://etherscan.io/address/${pool}` })], "Pool")?.explorerHref,
    ).toBeNull()
    expect(heroContractFromRows([row({ href: `javascript:alert('${pool}')` })], "Pool")?.explorerHref).toBeNull()
    expect(
      heroContractFromRows(
        [row({ href: "https://etherscan.io/address/0x1111111111111111111111111111111111111111" })],
        "Pool",
      )?.explorerHref,
    ).toBeNull()
  })
})
