import { describe, expect, it } from "vitest"
import { chainEscrowClaimable, chainRewardPositions, type RewardsDeps } from "../chain-rewards"
import type { ChainBorrowAccountRef } from "../chain-positions"

const WALLET = "0x00000000000000000000000000000000000000aa"
const USDC = "0x0000000000000000000000000000000000000c01"
const WETH = "0x0000000000000000000000000000000000000c02"

const account = (over: Partial<ChainBorrowAccountRef> = {}): ChainBorrowAccountRef => ({
  chainId: 31337,
  marketId: "3",
  spoke: "0xspoke",
  proxy: "0xproxy",
  poolSlug: "weth-usdc",
  ...over,
})

function deps(answers: Record<string, unknown>): RewardsDeps {
  return {
    lenses: [{ chainId: 31337, lens: "0x0000000000000000000000000000000000000001" }],
    priceUsd8: (_chainId, token) => (token === USDC ? 100_000_000n : token === WETH ? 300_000_000_000n : null),
    chain: () => ({
      readContract: async ({ functionName }) => {
        const answer = answers[functionName]
        if (answer instanceof Error) throw answer
        return answer
      },
    }),
  }
}

const MARKETS = [{ chainId: 31337, marketId: "3", tokens: [USDC, WETH], tokenDecimals: [6, 18] }]

describe("chainRewardPositions", () => {
  it("sums each account's supported uncollected fees in USD", async () => {
    const rows = await chainRewardPositions(
      deps({
        getAccountFees: [
          { supported: true, amounts: [2_000_000n, 10n ** 15n] }, // $2 + 0.001 WETH at $3,000 = $5
          { supported: true, amounts: [500_000n, 0n] }, // $0.50
          { supported: false, amounts: [9_000_000n, 0n] },
        ],
      }),
      WALLET,
      [account(), account({ marketId: "4", poolSlug: null })],
      MARKETS,
    )
    expect(rows).toEqual([
      { id: "fees:31337:3", marketId: "weth-usdc", claimableUsd6: 5_500_000n, earnedUsd6: 5_500_000n },
    ])
  })

  it("leaves out an account the Lens cannot read", async () => {
    expect(
      await chainRewardPositions(deps({ getAccountFees: new Error("revert") }), WALLET, [account()], MARKETS),
    ).toEqual([])
  })
})

describe("chainEscrowClaimable", () => {
  it("reads the PayoutEscrow per token", async () => {
    expect(
      await chainEscrowClaimable(deps({ getEscrowClaimable: [1_627_460n, 0n] }), 31337, WALLET, [USDC, WETH]),
    ).toEqual([
      { token: USDC, amount: 1_627_460n },
      { token: WETH, amount: 0n },
    ])
  })
})
