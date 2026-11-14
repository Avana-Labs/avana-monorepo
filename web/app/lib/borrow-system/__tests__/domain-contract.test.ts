import { describe, expect, it } from "vitest"
import type {
  ProductionReadAdapter,
  SandboxActionResult,
  SandboxReadAdapter,
  SyntheticTransactionReceipt,
  TransactionHistoryItem,
  TransactionIntent,
  TransactionPreview,
  TransactionResult,
} from "@/app/lib/borrow-system/contracts"
import { parseFixed } from "@/app/lib/credit-engine"
import type { BorrowPageData } from "@/app/lib/data/providers/borrow"
import type { PortfolioBorrowTabData } from "@/app/lib/data/providers/portfolio"
import type { AssetDetail, PoolDetail } from "@/app/lib/borrow-detail"

describe("borrow system contracts", () => {
  it("defines transaction intent, preview, and result contracts", () => {
    const intent: TransactionIntent = {
      id: "intent-1",
      actionType: "borrow",
      walletId: "wallet-1",
      marketId: "uni-v3-bluechip-weth-usdc",
      assetId: "uni-v3-bluechip:usdc",
      amountUsd6: parseFixed("500", 6),
      requestedAt: Date.now(),
      simulated: true,
    }

    const preview: TransactionPreview = {
      intent,
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

    const receipt: SyntheticTransactionReceipt = {
      id: "receipt-1",
      hash: "sim_123",
      status: "success",
      actionType: "borrow",
      simulated: true,
      timestamp: Date.now(),
    }

    const historyItem: TransactionHistoryItem = {
      id: "history-1",
      intentId: intent.id,
      walletId: intent.walletId,
      marketId: intent.marketId,
      assetId: intent.assetId,
      kind: intent.actionType,
      status: receipt.status,
      requestedAmountUsd6: intent.amountUsd6,
      executedAmountUsd6: intent.amountUsd6,
      simulated: true,
      timestamp: receipt.timestamp,
      hash: receipt.hash,
    }

    const result: TransactionResult = {
      id: receipt.id,
      hash: receipt.hash,
      status: receipt.status,
      actionType: receipt.actionType,
      simulated: receipt.simulated,
      timestamp: receipt.timestamp,
    }

    const sandboxResult: SandboxActionResult = {
      preview,
      receipt,
      result,
      historyItem,
      state: null as never,
    }

    expect(preview.intent.id).toBe(intent.id)
    expect(receipt.simulated).toBe(true)
    expect(historyItem.kind).toBe("borrow")
    expect(sandboxResult.result.hash).toBe("sim_123")
  })

  it("defines read adapter contracts for sandbox and production modes", () => {
    const sandboxReadAdapter: SandboxReadAdapter = {
      mode: "sandbox",
      readWalletSnapshot: async () => ({
        walletId: "wallet-1",
        transactionHistory: [],
        creditSnapshot: {
          collateralValueUsd6: 0n,
          borrowCapacityUsd6: 0n,
          availableBorrowCapacityUsd6: 0n,
          totalBorrowedUsd6: 0n,
          currentLtvWad: 0n,
          healthFactorWad: null,
        },
      }),
      readMarkets: async () => [],
      readBorrowPage: async () => ({}) as BorrowPageData,
      readPortfolioBorrow: async () => ({}) as PortfolioBorrowTabData,
      readPoolDetail: async () => null as PoolDetail | null,
      readAssetDetail: async () => null as AssetDetail | null,
    }

    const productionReadAdapter: ProductionReadAdapter = {
      mode: "production",
      readWalletSnapshot: async () => ({
        walletId: "wallet-1",
        transactionHistory: [],
        creditSnapshot: {
          collateralValueUsd6: 0n,
          borrowCapacityUsd6: 0n,
          availableBorrowCapacityUsd6: 0n,
          totalBorrowedUsd6: 0n,
          currentLtvWad: 0n,
          healthFactorWad: null,
        },
      }),
      readMarkets: async () => [],
      readBorrowPage: async () => ({}) as BorrowPageData,
      readPortfolioBorrow: async () => ({}) as PortfolioBorrowTabData,
      readPoolDetail: async () => null as PoolDetail | null,
      readAssetDetail: async () => null as AssetDetail | null,
    }

    expect(sandboxReadAdapter.mode).toBe("sandbox")
    expect(productionReadAdapter.mode).toBe("production")
  })
})
