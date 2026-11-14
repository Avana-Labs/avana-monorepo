import { describe, expect, it } from "vitest"
import { mapSwapTransactionHistoryToActivityRows } from "@/app/dashboard/swap-activity"
import type { SwapTransactionRecord } from "@/app/lib/swap-system"

const transaction: SwapTransactionRecord = {
  id: "swap-1",
  walletId: "wallet-1",
  inputAssetId: "eth",
  outputAssetId: "usdc",
  inputAmount: 0.001,
  outputAmount: 1.925,
  minimumOutputAmount: 1.915,
  quoteId: "quote-1",
  provider: "Avana mock router",
  exchangeRate: 1925,
  priceImpactPct: 0.08,
  slippageBps: 50,
  networkFeeUsd: 0.24,
  route: ["ETH", "USDC"],
  swapTransactionHash: "0xswap123",
  status: "confirmed",
  createdAt: 1_700_000_000_000,
  confirmedAt: 1_700_000_001_000,
}

describe("mapSwapTransactionHistoryToActivityRows", () => {
  it("maps a confirmed swap into dashboard activity", () => {
    expect(mapSwapTransactionHistoryToActivityRows([transaction])).toEqual([
      expect.objectContaining({
        product: "swap",
        kind: "swap",
        status: "confirmed",
        primaryLabel: "0.001 ETH → 1.925 USDC",
        secondaryLabel: "Avana mock router",
        txHash: "0xswap123",
      }),
    ])
  })

  it("maps expired swaps as failed activity", () => {
    expect(
      mapSwapTransactionHistoryToActivityRows([
        { ...transaction, status: "expired", swapTransactionHash: undefined, failureReason: "Quote expired." },
      ])[0],
    ).toMatchObject({ status: "failed", secondaryLabel: "Quote expired.", txHash: "swap-1" })
  })
})
