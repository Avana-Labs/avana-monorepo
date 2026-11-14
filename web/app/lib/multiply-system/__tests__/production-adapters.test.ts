import { describe, expect, it, vi } from "vitest"
import { ProductionMultiplyReadAdapter } from "@/app/lib/multiply-system/production-read-adapter"
import { ProductionMultiplyTransactionAdapter } from "@/app/lib/multiply-system/production-transaction-adapter"
import type { MultiplyTransactionIntent, MultiplyTransactionPreview } from "@/app/lib/multiply-system/contracts"

describe("multiply production adapters", () => {
  it("fails explicitly when a production source is not configured", async () => {
    const read = new ProductionMultiplyReadAdapter()
    const transaction = new ProductionMultiplyTransactionAdapter()

    await expect(read.readMarkets()).rejects.toThrow("Production multiply read adapter is not implemented")
    await expect(transaction.previewTransaction({} as MultiplyTransactionIntent)).rejects.toThrow(
      "Production multiply transaction adapter is not implemented",
    )
  })

  it("delegates production reads to their configured sources", async () => {
    const readWalletSnapshot = vi.fn(async () => null as never)
    const readMarkets = vi.fn(async () => [])
    const readMultiplyPage = vi.fn(async () => null as never)
    const readPortfolioMultiply = vi.fn(async () => null as never)
    const adapter = new ProductionMultiplyReadAdapter({
      readWalletSnapshot,
      readMarkets,
      readMultiplyPage,
      readPortfolioMultiply,
    })

    await adapter.readWalletSnapshot("wallet-1")
    await adapter.readMarkets()
    await adapter.readMultiplyPage("wallet-1")
    await adapter.readPortfolioMultiply("wallet-1")
    expect(readWalletSnapshot).toHaveBeenCalledWith("wallet-1")
    expect(readMarkets).toHaveBeenCalledOnce()
    expect(readMultiplyPage).toHaveBeenCalledWith("wallet-1")
    expect(readPortfolioMultiply).toHaveBeenCalledWith("wallet-1")
  })

  it("creates live intents and delegates preview and execution", async () => {
    const previewTransaction = vi.fn(
      async (intent: MultiplyTransactionIntent) => ({ intent }) as MultiplyTransactionPreview,
    )
    const executeTransaction = vi.fn(async () => null as never)
    const adapter = new ProductionMultiplyTransactionAdapter({
      previewTransaction,
      executeTransaction,
      now: () => 123,
      generateId: () => "intent-live",
    })
    const intent = adapter.createIntent({
      type: "multiply",
      walletId: "wallet-1",
      marketId: "market-1",
      collateralAmountUsd: 100,
      targetMultiplier: 2,
    })

    expect(intent).toMatchObject({ id: "intent-live", requestedAt: 123, simulated: false, actionType: "multiply" })
    await adapter.previewTransaction(intent)
    await adapter.executeTransaction(intent)
    expect(previewTransaction).toHaveBeenCalledWith(intent)
    expect(executeTransaction).toHaveBeenCalledWith(intent)
  })
})
