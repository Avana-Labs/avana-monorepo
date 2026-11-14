import { describe, expect, it } from "vitest"
import { borrowMarketFromSnapshot, type ConvexMarketSnapshot } from "@/app/lib/borrow-system/market-hydration"

const SPOKE_A = "0xcc00000000000000000000000000000000000001"
const SPOKE_B = "0xcc00000000000000000000000000000000000002"

function row(slug: string, scope: "pool" | "asset", spokeId: string | undefined): ConvexMarketSnapshot {
  return {
    slug,
    scope,
    chainId: 1,
    spokeId,
    suppliedUsd: 0,
    borrowedUsd: 0,
    availableUsd: 0,
    utilizationPct: 0,
    supplyApyPct: 0,
    borrowAprPct: 0,
    tvlUsd: 0,
  } as ConvexMarketSnapshot
}

describe("borrowMarketFromSnapshot relations", () => {
  const market = row("ethereum-market-1", "pool", SPOKE_A)
  const rows = [
    market,
    row("ethereum-a-usdc", "asset", SPOKE_A),
    row("ethereum-a-usdt", "asset", SPOKE_A.toUpperCase().replace("0X", "0x")),
    row("ethereum-b-gho", "asset", SPOKE_B),
    row("ethereum-market-2", "pool", SPOKE_A),
    row("ethereum-market-3", "pool", SPOKE_B),
  ]

  it("borrows only the debt reserves of the market's own CDP Spoke", () => {
    expect(borrowMarketFromSnapshot(market, rows).relations.supportedBorrowAssetIds).toEqual([
      "ethereum-a-usdc",
      "ethereum-a-usdt",
    ])
  })

  it("relates only markets on the same Spoke", () => {
    expect(borrowMarketFromSnapshot(market, rows).relations.relatedMarketIds).toEqual(["ethereum-market-2"])
  })

  it("matches on the chain only when a row does not name its Spoke", () => {
    const unnamed = row("ethereum-x-usdc", "asset", undefined)
    expect(borrowMarketFromSnapshot(market, [market, unnamed]).relations.supportedBorrowAssetIds).toEqual([
      "ethereum-x-usdc",
    ])
  })
})
