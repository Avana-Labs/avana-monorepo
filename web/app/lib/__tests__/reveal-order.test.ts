import { describe, expect, it } from "vitest"
import { BORROW_SPOKES, groupByDex, orderPoolsForDexGroups, type BorrowPoolRow } from "@/app/lib/borrow-sim"
import { orderLoopRowsByGroup } from "@/app/multiply/components/explore-loops-markets-table"

// Progressive reveal slices rows and then groups them. If the slice isn't already in group order,
// revealing the next chunk inserts rows into groups ABOVE the viewport and the page jumps.
describe("grouped progressive reveal order", () => {
  it("orders borrow pools so grouping a revealed prefix never reorders it", () => {
    const pools = [...BORROW_SPOKES].reverse().flatMap((spoke, index) => [
      { id: `a-${index}`, spoke: spoke.id },
      { id: `b-${index}`, spoke: spoke.id },
    ]) as unknown as BorrowPoolRow[]
    const ordered = orderPoolsForDexGroups(pools)
    for (let count = 1; count <= ordered.length; count++) {
      const prefix = ordered.slice(0, count)
      const grouped = groupByDex(prefix).flatMap((group) => group.spokes.flatMap((spoke) => spoke.rows))
      expect(grouped.map((row) => row.id)).toEqual(prefix.map((row) => row.id))
    }
  })

  it("orders multiply loops by collateral family, stable within a family", () => {
    const rows = ["WBTC", "USDC", "WETH", "LINK", "DAI", "cbBTC", "wstETH"].map((protocol, index) => ({
      protocol,
      index,
    }))
    const ordered = orderLoopRowsByGroup(rows).map((row) => row.protocol)
    expect(ordered).toEqual(["USDC", "DAI", "WETH", "wstETH", "WBTC", "cbBTC", "LINK"])
  })
})

describe("lend grouped reveal order", () => {
  it("pre-sorts each group by the table's default (name) so revealing only appends below", async () => {
    const { orderLendGroupsForReveal, paginateLendAssetGroups } =
      await import("@/app/lend/components/lend-asset-spokes")
    const group = (title: string, names: string[]) => ({ title, rows: names.map((name) => ({ name })) })
    const groups = orderLendGroupsForReveal([
      group("Stable", ["USDT", "DAI", "USDC"]),
      group("ETH", ["wstETH", "ETH"]),
    ] as never)
    let previous: string[] = []
    for (let count = 1; count <= 5; count++) {
      const shown = paginateLendAssetGroups(groups, 0, count).flatMap((g) =>
        [...g.rows].sort((a, b) => a.name.localeCompare(b.name)).map((row) => row.name),
      )
      expect(shown.slice(0, previous.length)).toEqual(previous)
      previous = shown
    }
  })
})
