import { describe, expect, it } from "vitest"
import type { Address } from "viem"
import { mergeChainLendPositions, readChainLendPositions, type LendChainClient } from "../chain-lend-positions"
import { emptyLendSystemState, lendMarketFromSnapshot } from "../market-hydration"
import { buildPortfolioLendData } from "../read-model"

const WALLET = "0x00000000000000000000000000000000000000aa" as Address
const USDC = "0x0000000000000000000000000000000000000c01"
const SPOKE_A = "0x0000000000000000000000000000000000000d01"
const SPOKE_B = "0x0000000000000000000000000000000000000d02"

const HUB_ASSETS = [
  {
    chainId: 31337,
    slug: "usdc-core",
    underlying: USDC,
    decimals: 6,
    lendReserves: [
      { spoke: SPOKE_A, reserveId: "0" },
      { spoke: SPOKE_B, reserveId: "2" },
    ],
  },
  {
    chainId: 31338,
    slug: "usdc-base",
    underlying: USDC,
    decimals: 6,
    lendReserves: [{ spoke: SPOKE_A, reserveId: "1" }],
  },
]

function chain(supplied: Record<string, bigint>, balance: bigint): LendChainClient {
  return {
    readContract: async ({ address, functionName, args = [] }) => {
      if (functionName === "balanceOf") return balance
      const value = supplied[`${address}:${args[0]}`]
      if (value === undefined) throw new Error("revert")
      return value
    },
  }
}

describe("readChainLendPositions", () => {
  it("sums a market's lend reserves and reads the wallet's balance, on every chain with a client", async () => {
    const read = await readChainLendPositions({
      client: (chainId) =>
        chainId === 31337
          ? chain({ [`${SPOKE_A}:0`]: 1_000_000_000n, [`${SPOKE_B}:2`]: 500_000_000n }, 250_000_000n)
          : null,
      wallet: WALLET,
      hubAssets: HUB_ASSETS,
    })
    expect(read).toEqual({ supplied: { "usdc-core": 1500 }, walletBalances: { "usdc-core": 250 } })
  })
})

describe("mergeChainLendPositions", () => {
  const market = lendMarketFromSnapshot(
    {
      slug: "usdc-core",
      scope: "lend",
      symbol: "USDC",
      assetPriceUsd: 1,
      suppliedUsd: 1e6,
      borrowedUsd: 0,
      availableUsd: 1e6,
      utilizationPct: 0,
      supplyApyPct: 4,
    },
    1,
    0,
  )
  const state = { ...emptyLendSystemState(WALLET, 0), markets: { "usdc-core": market } }

  it("opens an active position valued at the market's price, which the Lend tab reads", () => {
    const next = mergeChainLendPositions(
      state,
      WALLET,
      { supplied: { "usdc-core": 1500 }, walletBalances: { "usdc-core": 250 } },
      7,
    )
    expect(next.positions[`${WALLET}:usdc-core`]).toMatchObject({
      marketId: "usdc-core",
      currentSuppliedAmount: 1500,
      principalAmount: 1500,
      suppliedValueUsd: 1500,
      status: "active",
    })
    expect(next.walletBalances[WALLET]).toEqual({ "usdc-core": 250 })
    const tab = buildPortfolioLendData(WALLET, next)
    expect(tab.investments.map((i) => [i.marketId, i.balance, i.suppliedUsd, i.walletBalance])).toEqual([
      ["usdc-core", 1500, 1500, 250],
    ])
  })

  it("closes a position once the supply is withdrawn, and skips markets not loaded yet", () => {
    const open = mergeChainLendPositions(state, WALLET, { supplied: { "usdc-core": 1500 }, walletBalances: {} })
    const closed = mergeChainLendPositions(open, WALLET, { supplied: { "usdc-core": 0, other: 5 }, walletBalances: {} })
    expect(closed.positions).toEqual({})
  })
})
