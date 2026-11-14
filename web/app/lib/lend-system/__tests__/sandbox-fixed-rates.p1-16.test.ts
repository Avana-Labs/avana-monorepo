import { describe, expect, it } from "vitest"
import { catalogMarketToRow } from "@/app/lib/lend-system/read-model"
import { LEND_MARKET_CATALOG } from "@/app/lib/lend-system/market-ids"

describe("lend sandbox supply APY labeling", () => {
  it("p1-16: supply APY labels render a plain percentage without a sandbox fixed rates suffix", () => {
    const row = catalogMarketToRow(LEND_MARKET_CATALOG[0]!)
    expect(row.supplyApyLabel).not.toMatch(/sandbox fixed rates/i)
    expect(row.supplyApyLabel).toMatch(/^\d+\.\d{2}%$/)
  })
})
