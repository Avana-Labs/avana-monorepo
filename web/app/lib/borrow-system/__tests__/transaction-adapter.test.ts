import { describe, expect, it, vi } from "vitest"
import type { TransactionAdapter, TransactionIntent, TransactionPreview } from "@/app/lib/borrow-system/contracts"
import { ProductionTransactionAdapter } from "@/app/lib/borrow-system/production-transaction-adapter"
import { parseFixed } from "@/app/lib/credit-engine"

describe("transaction adapter contracts", () => {
  it("supports structured preview and execute shapes", async () => {
    const intent: TransactionIntent = {
      id: "intent-1",
      actionType: "borrow",
      walletId: "wallet-1",
      marketId: "market-1",
      assetId: "asset-1",
      amountUsd6: parseFixed("500", 6),
      requestedAt: Date.now(),
      simulated: true,
    }

    const adapter: TransactionAdapter = {
      mode: "sandbox",
      async previewTransaction(nextIntent) {
        const preview: TransactionPreview = {
          intent: nextIntent,
          allowed: true,
          warnings: [],
          validationErrors: [],
          riskLabel: "safe",
          before: {
            collateralValueUsd6: parseFixed("1000", 6),
            borrowCapacityUsd6: parseFixed("700", 6),
            availableBorrowCapacityUsd6: parseFixed("200", 6),
            totalBorrowedUsd6: parseFixed("500", 6),
            currentLtvWad: parseFixed("0.5", 18),
            healthFactorWad: parseFixed("2", 18),
          },
          after: {
            collateralValueUsd6: parseFixed("1000", 6),
            borrowCapacityUsd6: parseFixed("700", 6),
            availableBorrowCapacityUsd6: parseFixed("100", 6),
            totalBorrowedUsd6: parseFixed("600", 6),
            currentLtvWad: parseFixed("0.6", 18),
            healthFactorWad: parseFixed("1.7", 18),
          },
        }
        return preview
      },
      async executeTransaction(nextIntent) {
        return {
          preview: await this.previewTransaction(nextIntent),
          receipt: {
            id: "receipt-1",
            hash: "sim_123",
            status: "success" as const,
            actionType: nextIntent.actionType,
            simulated: true,
            timestamp: Date.now(),
          },
          result: {
            id: "receipt-1",
            hash: "sim_123",
            status: "success" as const,
            actionType: nextIntent.actionType,
            simulated: true,
            timestamp: Date.now(),
          },
          historyItem: {
            id: "history-1",
            intentId: nextIntent.id,
            walletId: nextIntent.walletId,
            marketId: nextIntent.marketId,
            assetId: nextIntent.assetId,
            kind: nextIntent.actionType,
            status: "success" as const,
            requestedAmountUsd6: nextIntent.amountUsd6,
            executedAmountUsd6: nextIntent.amountUsd6,
            simulated: true,
            timestamp: Date.now(),
            hash: "sim_123",
          },
          state: null as never,
        }
      },
    }

    const preview = await adapter.previewTransaction(intent)
    const execution = await adapter.executeTransaction(intent)

    expect(preview.allowed).toBe(true)
    expect(execution.receipt.hash).toBe("sim_123")
    expect(execution.historyItem.intentId).toBe(intent.id)
  })

  it("keeps the production adapter placeholder on the same interface and throws intentionally", async () => {
    const adapter = new ProductionTransactionAdapter()
    const intent: TransactionIntent = {
      id: "intent-1",
      actionType: "borrow",
      walletId: "wallet-1",
      marketId: "market-1",
      assetId: "asset-1",
      amountUsd6: parseFixed("500", 6),
      requestedAt: Date.now(),
      simulated: false,
    }

    await expect(adapter.previewTransaction(intent)).rejects.toThrow(
      "Production transaction adapter is not implemented",
    )
    await expect(adapter.executeTransaction(intent)).rejects.toThrow(
      "Production transaction adapter is not implemented",
    )
  })

  it("creates live intents and delegates production preview and execution", async () => {
    const previewTransaction = vi.fn(async (intent: TransactionIntent) => ({ intent }) as TransactionPreview)
    const executeTransaction = vi.fn(async () => null as never)
    const adapter = new ProductionTransactionAdapter({
      previewTransaction,
      executeTransaction,
      now: () => 123,
      generateId: () => "intent-live",
    })
    const intent = adapter.createIntent({
      type: "borrow",
      walletId: "wallet-1",
      marketId: "market-1",
      assetId: "asset-1",
      amountUsd6: 500_000_000n,
    })

    expect(intent).toMatchObject({ id: "intent-live", requestedAt: 123, simulated: false, actionType: "borrow" })
    expect(intent.payload).toMatchObject({ type: "borrow", assetId: "asset-1" })
    await adapter.previewTransaction(intent)
    await adapter.executeTransaction(intent)
    expect(previewTransaction).toHaveBeenCalledWith(intent)
    expect(executeTransaction).toHaveBeenCalledWith(intent)
  })
})
