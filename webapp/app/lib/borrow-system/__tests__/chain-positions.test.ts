import { describe, expect, it } from "vitest"
import { chainBorrowPositions, type AccountViewLike } from "@/app/lib/borrow-system/chain-positions"
import { borrowMarketFromSnapshot } from "@/app/lib/borrow-system/market-hydration"
import { currentCollateralValueUsd6, currentDebtValueUsd6 } from "@/app/lib/borrow-system/model"

const SPOKE = "0x00000000000000000000000000000000000000aa"
const PROXY = "0x00000000000000000000000000000000000000bb"
const USD = 10n ** 26n
const RAY = 10n ** 27n

const pool = borrowMarketFromSnapshot(
  {
    slug: "weth-usdc-30",
    scope: "pool",
    spokeId: SPOKE,
    lpPriceUsd: 2.5,
    suppliedUsd: 0,
    borrowedUsd: 0,
    availableUsd: 0,
    utilizationPct: 0,
    supplyApyPct: 0,
    borrowAprPct: 0,
    tvlUsd: 0,
    volumeUsd: 0,
    feesUsd: 0,
  },
  [],
)
const markets = { [pool.id]: pool }
const accounts = [{ chainId: 31337, marketId: "7", spoke: SPOKE, proxy: PROXY, poolSlug: pool.id }]
const reserves = [
  { chainId: 31337, spoke: SPOKE, reserveId: "1", asset: "0xusdc", assetSlug: "usdc-a", decimals: 6, priceUsd8: "100000000" },
  { chainId: 31337, spoke: SPOKE, reserveId: "2", asset: "0xusdt", assetSlug: "usdt-a", decimals: 6, priceUsd8: "99000000" },
]

function view(over: Partial<AccountViewLike>): AccountViewLike {
  return {
    marketId: 7n,
    spoke: SPOKE,
    proxy: PROXY,
    deployed: true,
    totalCollateralValue: 43_750n * USD,
    totalDebtValueRay: 0n,
    debts: [],
    markets: [{ collateralEnabled: true, suppliedAssets: 1n }],
    ...over,
  }
}

describe("chainBorrowPositions", () => {
  it("values the collateral at the account's chain value", () => {
    const { collateralPositions, debtPositions } = chainBorrowPositions([{ chainId: 31337, view: view({}) }], accounts, reserves, markets)
    expect(collateralPositions).toHaveLength(1)
    expect(collateralPositions[0]!.marketId).toBe(pool.id)
    expect(currentCollateralValueUsd6(collateralPositions[0]!, pool)).toBe(43_750_000_000n)
    expect(debtPositions).toEqual([])
  })

  it("takes a lone debt at the account's debt value", () => {
    const { debtPositions } = chainBorrowPositions(
      [
        {
          chainId: 31337,
          view: view({
            totalDebtValueRay: 1_200n * USD * RAY,
            debts: [
              { reserveId: 1n, asset: "0xusdc", total: 1_200_000_000n },
              { reserveId: 2n, asset: "0xusdt", total: 0n },
            ],
          }),
        },
      ],
      accounts,
      reserves,
      markets,
    )
    expect(debtPositions).toHaveLength(1)
    expect(debtPositions[0]).toMatchObject({ assetId: "usdc-a", marketId: pool.id, spokeId: SPOKE })
    expect(currentDebtValueUsd6(debtPositions[0]!)).toBe(1_200_000_000n)
  })

  it("values several debts at their Hub prices", () => {
    const { debtPositions } = chainBorrowPositions(
      [
        {
          chainId: 31337,
          view: view({
            totalDebtValueRay: 1_992n * USD * RAY,
            debts: [
              { reserveId: 1n, asset: "0xusdc", total: 1_200_000_000n },
              { reserveId: 2n, asset: "0xusdt", total: 800_000_000n },
            ],
          }),
        },
      ],
      accounts,
      reserves,
      markets,
    )
    expect(debtPositions.map((d) => currentDebtValueUsd6(d))).toEqual([1_200_000_000n, 792_000_000n])
  })

  it("leaves out accounts of markets the Borrow list does not show", () => {
    const out = chainBorrowPositions([{ chainId: 31337, view: view({ marketId: 8n }) }], accounts, reserves, markets)
    expect(out).toEqual({ collateralPositions: [], debtPositions: [] })
  })
})
