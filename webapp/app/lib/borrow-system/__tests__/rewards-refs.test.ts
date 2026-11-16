import { describe, expect, it } from "vitest"
import { rewardsDeps, rewardsMarkets } from "@/app/lib/borrow-system/use-chain-borrow-positions"

const USDC = "0x00000000000000000000000000000000000000E1"
const refs = {
  lenses: [{ chainId: 31337, lens: "0x00000000000000000000000000000000000000d1" }],
  accounts: [],
  debtReserves: [],
  markets: [
    { chainId: 31337, marketId: "7", spoke: "0xaa", poolSlug: "weth-usdc", tokens: ["0xweth", USDC], tokenDecimals: [18, 6] },
    { chainId: 31337, marketId: "8", spoke: "0xaa", poolSlug: "old" },
  ],
  tokenPrices: [{ chainId: 31337, token: USDC.toLowerCase(), priceUsd8: "100000000" }],
}

describe("rewards inputs from borrowAccounts", () => {
  it("lists only markets with their pool tokens", () => {
    expect(rewardsMarkets(refs)).toEqual([{ chainId: 31337, marketId: "7", tokens: ["0xweth", USDC], tokenDecimals: [18, 6] }])
  })

  it("prices a pool token on its chain, case-insensitively, and nothing else", () => {
    const deps = rewardsDeps(refs)
    expect(deps.priceUsd8(31337, USDC)).toBe(100_000_000n)
    expect(deps.priceUsd8(31338, USDC)).toBeNull()
    expect(deps.priceUsd8(31337, "0xweth")).toBeNull()
    expect(deps.lenses).toBe(refs.lenses)
  })
})
