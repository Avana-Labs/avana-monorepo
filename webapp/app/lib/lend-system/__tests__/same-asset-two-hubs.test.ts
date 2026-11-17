import { describe, expect, it } from "vitest"
import { lendMarketFromSnapshot } from "../market-hydration"
import type { LendSystemState } from "../model/types"
import { buildLendPageData } from "../read-model"

const snap = (slug: string, hubLabel: string, suppliedUsd: number, availableUsd: number) => ({
  slug,
  scope: "lend",
  symbol: "GHO",
  hubId: `hub-${slug}`,
  hubLabel,
  category: "stable",
  assetPriceUsd: 1,
  suppliedUsd,
  borrowedUsd: suppliedUsd - availableUsd,
  availableUsd,
  utilizationPct: ((suppliedUsd - availableUsd) / suppliedUsd) * 100,
  supplyApyPct: 0,
})

describe("the Lend list with one asset on two Hubs", () => {
  it("gives each row its own market's id, link and figures", () => {
    const base = lendMarketFromSnapshot(snap("gho-base", "Base Hub", 21_000_000, 20_970_000), 1, 0)
    const ethereum = lendMarketFromSnapshot(snap("gho-ethereum-hub", "Ethereum Hub", 9_000_000, 6_000_000), 2, 0)
    const state: LendSystemState = {
      now: 0,
      markets: { [base.marketId]: base, [ethereum.marketId]: ethereum },
      positions: {},
      walletBalances: {},
      transactions: [],
    }

    const rows = buildLendPageData("guest", state).assetGroups.flatMap((group) => group.rows)
    const byMarket = new Map(rows.map((row) => [row.market, row]))

    expect(rows).toHaveLength(2)
    expect(byMarket.get("gho-base")).toMatchObject({
      marketId: "gho-base",
      href: "/lend/markets/gho-base",
      totalDepositsSortValue: 21_000_000,
      availableLiquiditySortValue: 20_970_000,
    })
    expect(byMarket.get("gho-ethereum-hub")).toMatchObject({
      marketId: "gho-ethereum-hub",
      href: "/lend/markets/gho-ethereum-hub",
      totalDepositsSortValue: 9_000_000,
      availableLiquiditySortValue: 6_000_000,
      utilizationValue: expect.closeTo(1 / 3, 6),
    })
  })
})
