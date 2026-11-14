import { describe, expect, it } from "vitest"
import { resolveMultiplyTokenLogo } from "@/lib/multiply-token-logo"

describe("resolveMultiplyTokenLogo", () => {
  it("matches catalog symbols regardless of casing", () => {
    expect(resolveMultiplyTokenLogo("STETH")).toBe(resolveMultiplyTokenLogo("stETH"))
    expect(resolveMultiplyTokenLogo("WSTETH")).toBe(resolveMultiplyTokenLogo("wstETH"))
    expect(resolveMultiplyTokenLogo("CBBTC")).toBe(resolveMultiplyTokenLogo("cbBTC"))
    expect(resolveMultiplyTokenLogo("CRVUSD")).toBe(resolveMultiplyTokenLogo("crvUSD"))
  })

  it("never returns an empty string", () => {
    expect(resolveMultiplyTokenLogo("ETH").length).toBeGreaterThan(0)
    expect(resolveMultiplyTokenLogo("UNKNOWN_TOKEN_XYZ").length).toBeGreaterThan(0)
  })
})
