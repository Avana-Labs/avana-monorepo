import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("collateral pool label disambiguation", () => {
  // Every pool name cell reads the same way: TVL, flipping to the risk premium on desktop hover.
  // The pair spot rate ("84,457.84 USDC") read like the LP price and fell back for unpriced legs,
  // so one table mixed two formats. The DEX/LP-type (venue) string stays dropped; section
  // headings carry it.
  it("p1-14: pool name cells render one TVL / premium sub-label, no venue string", () => {
    const source = readFileSync(resolve(__dirname, "../collateral-pools-table.tsx"), "utf8")
    expect(source).toMatch(/const tvl = `\$\{compact\(pool\.tvlUsd\)\} \$\{t\("TVL"\)\}`/)
    expect(source).toMatch(/<HoverFlip front=\{tvl\} back=\{premium\}/)
    expect(source).not.toMatch(/formatPairRate\(/)
    expect(source).not.toMatch(/allocationVenueLabel\(|`\$\{pool\.venue\}/)
  })
})
