import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"
import { isNegativeMultiplyApy } from "@/app/multiply/components/explore-loops-markets-table"

describe("isNegativeMultiplyApy", () => {
  it("identifies loss-making strategies from formatted APY labels", () => {
    expect(isNegativeMultiplyApy("-2.92%")).toBe(true)
    expect(isNegativeMultiplyApy("7.83%")).toBe(false)
    expect(isNegativeMultiplyApy("—")).toBe(false)
  })
})

describe("multiply table on every viewport", () => {
  it("renders the shared table on phones instead of a separate card view", () => {
    const source = readFileSync(resolve(__dirname, "../explore-loops-markets-table.tsx"), "utf8")
    expect(source).not.toMatch(/MobileLoopCard/)
    expect(source).not.toMatch(/useMediaQuery/)
    expect(source).toMatch(/TABLE_INDEX_PHONE_HIDDEN/)
    // Empty categories still say so inside the table.
    expect(source).toContain('t("No loops in this category yet.")')
  })
})

describe("multiply capacity table", () => {
  it("shows Capacity Filled before Available and removes the Deleverage row action", () => {
    const source = readFileSync(resolve(__dirname, "../explore-loops-markets-table.tsx"), "utf8")
    const section = source.slice(source.indexOf("function LoopMarketsSection"), source.indexOf("const LoopTableRow"))
    const row = source.slice(source.indexOf("const LoopTableRow"), source.indexOf("function TrendingLoopCard"))

    expect(section.indexOf('t("Capacity Filled")')).toBeLessThan(section.indexOf('t("Available")'))
    expect(row).toContain("<CapacityFilled value={row.capacityFilledPct} />")
    expect(row).not.toMatch(/Deleverage/)
  })
})
