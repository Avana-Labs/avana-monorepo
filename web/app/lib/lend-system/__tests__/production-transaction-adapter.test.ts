import { describe, expect, it, vi } from "vitest"
import { ProductionLendTransactionAdapter } from "@/app/lib/lend-system/production-transaction-adapter"
import type { LendActionResult, LendTransactionPreview } from "@/app/lib/lend-system/contracts"

describe("ProductionLendTransactionAdapter", () => {
  it("creates non-simulated intents and delegates preview/execute to injected production handlers", async () => {
    const preview: LendTransactionPreview = {
      intent: {
        id: "intent-live",
        actionType: "claim",
        walletId: "wallet-1",
        marketId: "rewards",
        requestedAt: 123,
        simulated: false,
      },
      allowed: true,
      warnings: [],
      validationErrors: [],
      before: {
        suppliedAmount: 10,
        suppliedValueUsd: 100,
        principalAmount: 9,
        interestEarned: 1,
        rewardsEarnedUsd: 12,
        totalEarnedUsd: 13,
        currentApy: 0.08,
      },
      after: {
        suppliedAmount: 10,
        suppliedValueUsd: 100,
        principalAmount: 9,
        interestEarned: 1,
        rewardsEarnedUsd: 0,
        totalEarnedUsd: 1,
        currentApy: 0.08,
      },
    }

    const result: LendActionResult = {
      preview,
      receipt: {
        id: "tx-live",
        hash: "0xlive",
        status: "success",
        actionType: "claim",
        simulated: false,
        timestamp: 456,
      },
      historyItem: {
        id: "tx-live",
        intentId: "intent-live",
        walletId: "wallet-1",
        marketId: "rewards",
        kind: "claim",
        status: "success",
        asset: "Rewards",
        amount: 12,
        simulated: false,
        timestamp: 456,
        hash: "0xlive",
      },
      state: {
        now: 456,
        markets: {},
        positions: {},
        walletBalances: {},
        transactions: [],
      },
    }

    const previewTransaction = vi.fn().mockResolvedValue(preview)
    const executeTransaction = vi.fn().mockResolvedValue(result)

    const adapter = new ProductionLendTransactionAdapter({
      now: () => 123,
      generateId: () => "intent-live",
      previewTransaction,
      executeTransaction,
    })

    const intent = adapter.createIntent({
      type: "claim",
      walletId: "wallet-1",
    })

    expect(intent).toEqual({
      id: "intent-live",
      actionType: "claim",
      walletId: "wallet-1",
      marketId: "rewards",
      positionId: undefined,
      requestedAt: 123,
      simulated: false,
      payload: {
        type: "claim",
        walletId: "wallet-1",
      },
    })

    await expect(adapter.previewTransaction(intent)).resolves.toEqual(preview)
    await expect(adapter.executeTransaction(intent)).resolves.toEqual(result)
    expect(previewTransaction).toHaveBeenCalledWith(intent)
    expect(executeTransaction).toHaveBeenCalledWith(intent)
  })

  it("keeps throwing intentionally until real production transaction handlers are provided", async () => {
    const adapter = new ProductionLendTransactionAdapter({ now: () => 123, generateId: () => "intent-live" })
    const intent = adapter.createIntent({
      type: "deposit",
      walletId: "wallet-1",
      marketId: "eth",
      depositAmount: 1,
      walletBalance: 3,
    })

    await expect(adapter.previewTransaction(intent)).rejects.toThrow(
      "Production lend transaction adapter is not implemented",
    )
    await expect(adapter.executeTransaction(intent)).rejects.toThrow(
      "Production lend transaction adapter is not implemented",
    )
  })
})
