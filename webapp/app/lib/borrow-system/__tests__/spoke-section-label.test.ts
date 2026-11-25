import { describe, expect, it } from "vitest"
import { emptyBorrowSystemState, mergeConvexMarketSnapshots, type ConvexMarketSnapshot } from "../market-hydration"
import { selectBorrowMarketSummaries, spokeSectionLabel } from "../selectors"
import { groupByDex } from "@/app/lib/borrow-market-rows"

const SPOKE = "0xcc00000000000000000000000000000000000001"

function pool(slug: string, venueLabel: string, spokeName?: string): ConvexMarketSnapshot {
  return {
    slug,
    scope: "pool",
    chainId: 31337,
    spokeId: SPOKE,
    ...(spokeName ? { spokeName } : {}),
    venueLabel,
    suppliedUsd: 0,
    borrowedUsd: 0,
    availableUsd: 0,
    utilizationPct: 0,
    supplyApyPct: 0,
    borrowAprPct: 0,
    tvlUsd: 0,
  } as ConvexMarketSnapshot
}

describe("Borrow section titles", () => {
  it("names a section after its Spoke as an LP group", () => {
    expect(spokeSectionLabel("Uniswap v3 Stable")).toBe("Uniswap v3 Stable LPs")
    expect(spokeSectionLabel("Curve Stable LPs")).toBe("Curve Stable LPs")
    expect(spokeSectionLabel("  ")).toBe("")
    expect(spokeSectionLabel(undefined)).toBe("")
  })

  it("gives one Spoke's markets of different fee tiers one section titled by the Spoke", () => {
    const state = mergeConvexMarketSnapshots(emptyBorrowSystemState("w"), [
      pool("a", "Uniswap v3 · 0.05 %", "Uniswap v3 Blue-chip"),
      pool("b", "Uniswap v3 · 0.3 %", "Uniswap v3 Blue-chip"),
    ])
    const groups = groupByDex(selectBorrowMarketSummaries(state, "w"))
    const sections = groups.flatMap((group) => group.spokes)
    expect(sections.map((section) => [section.spoke.label, section.rows.length])).toEqual([
      ["Uniswap v3 Blue-chip LPs", 2],
    ])
  })

  it("falls back to the market's venue label without a Spoke name", () => {
    const state = mergeConvexMarketSnapshots(emptyBorrowSystemState("w"), [pool("a", "Uniswap v3 · 0.05 %")])
    expect(selectBorrowMarketSummaries(state, "w")[0].spokeLabel).toBe("Uniswap v3 · 0.05 %")
  })
})
