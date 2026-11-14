import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("dashboard wallet analytics honesty", () => {
  it("p1-04: does not ship fabricated TOKEN_PNL_BASIS_MULTIPLIER or eth-usdc-lp fee fiction", () => {
    const source = readFileSync(resolve(__dirname, "../dashboard-wallet-tab.tsx"), "utf8")
    expect(source).not.toMatch(/TOKEN_PNL_BASIS_MULTIPLIER/)
    expect(source).not.toMatch(/eth-usdc-lp/)
    expect(source).not.toMatch(/feesUsd:\s*0\.564/)
  })
})
