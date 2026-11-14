import { describe, expect, it } from "vitest"
import {
  inferLegacyDebtAssetId,
  swapTransactionToReceiptData,
  toReceiptData,
} from "@/app/sandbox/transactions/[hash]/synthetic-transaction-client"
import type { SwapTransactionRecord } from "@/app/lib/swap-system"
import { formatActionFeeSummary } from "@/app/lib/action-system/formatters"

describe("swapTransactionToReceiptData", () => {
  it("maps canonical swap metadata to the shared receipt", () => {
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

    expect(swapTransactionToReceiptData(transaction)).toMatchObject({
      title: "Swap ETH for USDC",
      amountRowLabel: "Sold",
      amountLabel: "0.001 ETH",
      rateLabel: "Received",
      rateValue: "1.925 USDC",
      hash: "0xswap123",
      quoteId: "quote-1",
    })
  })
})

describe("toReceiptData — durable swap row (cross-device / no in-session history)", () => {
  const swapRow = {
    at: 1_700_000_001_000,
    syntheticTxHash: "0xswap123",
    amountUsd: 3.21,
    product: "swap",
    kind: "swap",
    status: "success",
    swapInputSymbol: "ETH",
    swapOutputSymbol: "USDC",
    swapInputAmount: 0.001,
    swapOutputAmount: 1.925,
    swapProvider: "Avana mock router",
    swapQuoteId: "quote-1",
    swapNetworkFeeUsd: 0.24,
    swapMinOutputAmount: 1.915,
    swapPriceImpactPct: 0.08,
    swapSlippageBps: 50,
  }

  it("renders the full swap breakdown from the persisted row alone", () => {
    const data = toReceiptData(swapRow)
    expect(data).toMatchObject({
      title: "Swap ETH for USDC",
      amountRowLabel: "Sold",
      amountLabel: "0.001 ETH",
      rateLabel: "Received",
      rateValue: "1.925 USDC",
      marketValue: "Avana mock router",
      networkFeeUsd: 0.24,
      hash: "0xswap123",
      quoteId: "quote-1",
    })
    expect(data.metrics).toEqual([
      { id: "minimum-received", label: "Minimum received", value: "1.915 USDC" },
      { id: "price-impact", label: "Price impact", value: "0.08%" },
      { id: "slippage", label: "Max slippage", value: "0.50%" },
    ])
  })

  it("uses the failure summary and omits economics for a failed swap row", () => {
    const data = toReceiptData({
      at: 1_700_000_001_000,
      syntheticTxHash: "0xfail",
      amountUsd: 0,
      product: "swap",
      kind: "swap",
      status: "failed",
      swapInputSymbol: "ETH",
      swapOutputSymbol: "USDC",
      swapInputAmount: 0.001,
      swapOutputAmount: 0,
    })
    expect(data.description).toBe("Swap did not complete.")
    // A durable row seeded before this change (or a failed swap) carries no economics.
    expect(data.metrics).toBeUndefined()
    // Falls back to a hash-derived network fee when none was persisted.
    expect(data.networkFeeUsd).toBeGreaterThan(0)
  })
})

describe("toReceiptData — synthetic (non-swap) row", () => {
  const baseRow = {
    at: 1_700_000_002_000,
    syntheticTxHash: "sim_lend_abc123",
    amountUsd: 1000,
    product: "lend",
    kind: "deposit",
    status: "success",
    marketSlug: "usdc",
  }

  it("records the 15 bps platform fee — equal to the review estimate (#F1)", () => {
    const data = toReceiptData(baseRow)
    expect(data.networkFeeUsd).toBeCloseTo(1.5, 9)
    expect(formatActionFeeSummary(baseRow.amountUsd)).toBe("~ $1.50")
  })

  it("derives a real token symbol from the market slug when no asset is stored (#F3)", () => {
    // No assetId → fall back to the market slug so the icon resolves instead of "?".
    const data = toReceiptData(baseRow)
    expect(data.symbol).toBe("USDC")
    expect(data.symbol).not.toBe("Asset")
    expect(data.title).toBe("Deposit USDC")
  })

  it("uppercases the lowercase market label (#F3)", () => {
    const data = toReceiptData(baseRow)
    expect(data.marketValue).toBe("USDC")
  })

  it("prefers the explicit asset id over the market slug for the symbol", () => {
    const data = toReceiptData({ ...baseRow, assetId: "weth", marketSlug: "usdc" })
    expect(data.symbol).toBe("WETH")
    expect(data.marketValue).toBe("USDC")
  })

  it("recovers the debt asset for legacy borrow and repay receipts", () => {
    const legacy = { product: "borrow", kind: "repay", marketSlug: "aero-slipstream-bluechip-cbbtc-usdc" }
    expect(inferLegacyDebtAssetId(legacy)).toBe("usdc")
    expect(toReceiptData({ ...baseRow, ...legacy }).title).toBe("Repay USDC")
    expect(inferLegacyDebtAssetId({ ...legacy, kind: "deposit" })).toBeUndefined()
  })
})
