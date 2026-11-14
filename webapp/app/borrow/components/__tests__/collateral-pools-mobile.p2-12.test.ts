import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

describe("Collateral pools on phones", () => {
  it("renders the shared pinned-column table instead of a separate card list", () => {
    const source = readFileSync(resolve(__dirname, "../collateral-pools-table.tsx"), "utf8")
    expect(source).not.toMatch(/CollateralPoolsList|SpokeMobileSection|MarketMobileCard/)
    // The spoke sections are no longer hidden below md.
    expect(source).not.toMatch(/hidden space-y-10 md:block/)
    expect(source).toMatch(/TABLE_INDEX_PHONE_HIDDEN/)
  })
})
