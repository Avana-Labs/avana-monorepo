import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { mergeSwapSessionStates } from "@/app/lib/swap-system/storage"
import type { SwapSystemState } from "@/app/lib/swap-system/transaction-adapter"

const baseState = (): SwapSystemState => ({
  balances: [
    {
      id: "wallet-eth",
      walletId: "w1",
      assetId: "eth",
      symbol: "ETH",
      name: "ETH",
      amount: 1,
      valueUsd: 3000,
      sourceType: "wallet",
      isLpToken: false,
    },
  ],
  allowances: {},
  transactions: [],
})

describe("P2-05 action network guards + swap OCC", () => {
  it("suppresses same-tab reload while persisting to avoid setState loops", () => {
    const source = readFileSync(resolve(__dirname, "../use-swap-session.ts"), "utf8")
    expect(source).toMatch(/writingRef\.current = true/)
    expect(source).toMatch(/if \(writingRef\.current\) return/)
    expect(source).toMatch(/if \(next\.revision === revisionRef\.current\) return/)
  })

  it("guards swap and rewards claim with useActionNetworkGuard", () => {
    const swapSource = readFileSync(resolve(__dirname, "../../../swap/swap-page-client.tsx"), "utf8")
    const rewardsSource = readFileSync(
      resolve(__dirname, "../../../components/action-page/rewards-action-page-client.tsx"),
      "utf8",
    )
    expect(swapSource).toMatch(/useActionNetworkGuard/)
    expect(rewardsSource).toMatch(/useActionNetworkGuard/)
  })

  it("merges stale swap localStorage writes by revision instead of blind overwrite", () => {
    const older = { ...baseState(), revision: 2, balances: [{ ...baseState().balances[0]!, amount: 0.5 }] }
    const newer = {
      ...baseState(),
      revision: 3,
      transactions: [
        {
          id: "tx-1",
          walletId: "w1",
          inputAssetId: "eth",
          outputAssetId: "usdc",
          inputAmount: 0.1,
          outputAmount: 300,
          minimumOutputAmount: 295,
          quoteId: "q1",
          provider: "mock",
          exchangeRate: 3000,
          priceImpactPct: 0.1,
          slippageBps: 50,
          networkFeeUsd: 0.04,
          route: ["mock"],
          status: "confirmed" as const,
          createdAt: 1,
        },
      ],
    }

    const merged = mergeSwapSessionStates(older, newer)
    expect(merged.revision).toBe(3)
    expect(merged.transactions).toHaveLength(1)
    expect(merged.balances[0]?.amount).toBe(newer.balances[0]?.amount)
  })
})
