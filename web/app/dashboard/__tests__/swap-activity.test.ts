import { describe, expect, it } from "vitest"
import {
  mapConvexSwapTransactionsToActivityRows,
  mapSwapTransactionHistoryToActivityRows,
} from "@/app/dashboard/swap-activity"
import type { SwapTransactionRecord } from "@/app/lib/swap-system"
import type { DurableSwapTransaction } from "@/app/lib/swap-system/use-swap-session"

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

  it("shows no debit for a failed/expired swap (nothing moved) but does for a confirmed one (#31)", () => {
    const confirmed = mapSwapTransactionHistoryToActivityRows([transaction])[0]
    expect(confirmed.amountUsd).toBeLessThan(0)

    for (const status of ["expired", "failed", "rejected"] as const) {
      const row = mapSwapTransactionHistoryToActivityRows([{ ...transaction, status }])[0]
      expect(row.amountUsd).toBe(0)
    }
  })
})

const durable: DurableSwapTransaction = {
  id: "convex-doc-1",
  intentId: "swap-1",
  status: "success",
  inputSymbol: "ETH",
  outputSymbol: "USDC",
  inputAmount: 0.001,
  outputAmount: 1.925,
  amountUsd: 1.934,
  hash: "sim-swap-abc",
  at: 1_700_000_000_000,
}

describe("mapConvexSwapTransactionsToActivityRows (#15 follow-on)", () => {
  it("maps a durable confirmed swap, keyed on the client intentId for dedup", () => {
    const [row] = mapConvexSwapTransactionsToActivityRows([durable])
    expect(row).toMatchObject({
      id: "swap-1", // intentId — matches the in-session row so the dashboard dedups them
      product: "swap",
      status: "confirmed",
      primaryLabel: "0.001 ETH → 1.925 USDC",
      txHash: "sim-swap-abc",
    })
    expect(row.amountUsd).toBeLessThan(0)
  })

  it("shows no debit for a non-confirmed durable swap", () => {
    for (const status of ["failed", "pending"] as const) {
      expect(mapConvexSwapTransactionsToActivityRows([{ ...durable, status }])[0].amountUsd).toBe(0)
    }
  })

  it("dedups against an in-session row by id (session id === durable intentId)", () => {
    const sessionRows = mapSwapTransactionHistoryToActivityRows([transaction]) // transaction.id === "swap-1"
    const sessionIds = new Set(sessionRows.map((r) => r.id))
    const durableRows = mapConvexSwapTransactionsToActivityRows([durable]).filter((r) => !sessionIds.has(r.id))
    expect(durableRows).toHaveLength(0) // the durable copy of the same swap is filtered out
  })
})
