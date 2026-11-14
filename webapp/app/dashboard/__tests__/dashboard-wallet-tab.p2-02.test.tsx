import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("DashboardWalletTab pool balance cell", () => {
  it("P2-02: renders a non-redundant pool balance (LP amount over USD, or USD alone)", () => {
    const source = readFileSync(resolve(__dirname, "../dashboard-wallet-tab.tsx"), "utf8")
    const cell = source.slice(source.indexOf("function PoolBalanceCell"), source.indexOf("function PoolLtvCell"))
    expect(cell).toMatch(/row\.unitPriceUsd[\s\S]{0,180}formatPoolAmount\(row\.amount\)/)
    expect(cell).toMatch(/exact\(row\.valueUsd\)/)
    // Pool fees are not sourced yet, so no fee line is rendered.
    expect(cell).not.toMatch(/Unclaimed fees/)
  })
})
