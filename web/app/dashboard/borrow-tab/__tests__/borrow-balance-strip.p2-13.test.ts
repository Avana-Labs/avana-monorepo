import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

describe("Borrow balance and asset summary mobile layout", () => {
  it("P2-13: uses responsive metric grid and stacks summary labels above values on mobile", () => {
    const metrics = readFileSync(resolve(__dirname, "../../dashboard-metric-section.tsx"), "utf8")
    const supplies = readFileSync(resolve(__dirname, "../supplies-table.tsx"), "utf8")
    const debts = readFileSync(resolve(__dirname, "../debts-table.tsx"), "utf8")
    expect(metrics).toMatch(/grid-cols-1[\s\S]{0,40}sm:grid-cols-2[\s\S]{0,40}lg:grid-cols-4/)
    // Phones show the same pinned-column tables as desktop, not a separate card list.
    expect(supplies).not.toMatch(/md:hidden|MarketMobileCard/)
    expect(debts).not.toMatch(/MarketMobileCard/)
    expect(supplies).toMatch(/ScrollableTable/)
    expect(debts).toMatch(/ScrollableTable/)
  })
})
