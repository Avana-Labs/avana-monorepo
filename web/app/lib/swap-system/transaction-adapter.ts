import { MockSwapProvider, isQuoteUsable, type SwapQuote, type SwapProvider } from "./quote-provider"
import { getSwapAsset } from "./catalog"
import type { UserAssetBalance } from "./contracts"

export type SwapTransactionStatus =
  "approval_pending" | "approval_confirmed" | "swap_pending" | "confirmed" | "failed" | "rejected" | "expired"

export type SwapTransactionRecord = {
  id: string
  walletId: string
  inputAssetId: string
  outputAssetId: string
  inputAmount: number
  outputAmount: number
  minimumOutputAmount: number
  quoteId: string
  provider: string
  exchangeRate: number
  priceImpactPct: number
  slippageBps: number
  networkFeeUsd: number
  route: string[]
  approvalTransactionHash?: string
  swapTransactionHash?: string
  status: SwapTransactionStatus
  failureReason?: string
  createdAt: number
  confirmedAt?: number
}

export type SwapSystemState = {
  balances: UserAssetBalance[]
  allowances: Record<string, number>
  transactions: SwapTransactionRecord[]
}

export type SwapExecutionOptions = {
  rejectApproval?: boolean
  failApproval?: boolean
  rejectSwap?: boolean
  revertSwap?: boolean
  now?: number
}

type AdapterOptions = {
  readState: () => SwapSystemState
  writeState: (state: SwapSystemState) => void
  provider?: SwapProvider
  now?: () => number
  generateId?: (prefix: string) => string
}

function defaultId(prefix: string) {
  return `${prefix}-${Math.random().toString(36).slice(2, 10)}`
}

function allowanceKey(walletId: string, assetId: string) {
  return `${walletId}:${assetId}`
}

function cloneState(state: SwapSystemState): SwapSystemState {
  return {
    balances: state.balances.map((balance) => ({ ...balance })),
    allowances: { ...state.allowances },
    transactions: state.transactions.map((transaction) => ({ ...transaction })),
  }
}

function upsertWalletBalance(
  balances: UserAssetBalance[],
  walletId: string,
  assetId: string,
  delta: number,
): UserAssetBalance[] {
  const existingIndex = balances.findIndex(
    (balance) => balance.walletId === walletId && balance.assetId === assetId && balance.sourceType === "wallet",
  )
  if (existingIndex >= 0) {
    return balances.map((balance, index) =>
      index === existingIndex ? { ...balance, amount: Math.max(0, balance.amount + delta) } : balance,
    )
  }
  if (delta <= 0) return balances
  return [
    ...balances,
    {
      id: `wallet-${walletId}-${assetId}`,
      walletId,
      assetId,
      amount: delta,
      sourceType: "wallet",
    },
  ]
}

function recordFailure(
  quote: SwapQuote,
  walletId: string,
  status: SwapTransactionStatus,
  failureReason: string,
  now: number,
  id: string,
): SwapTransactionRecord {
  return {
    id,
    walletId,
    inputAssetId: quote.inputAssetId,
    outputAssetId: quote.outputAssetId,
    inputAmount: quote.inputAmount,
    outputAmount: 0,
    minimumOutputAmount: quote.minimumOutputAmount,
    quoteId: quote.id,
    provider: quote.provider,
    exchangeRate: quote.exchangeRate,
    priceImpactPct: quote.priceImpactPct,
    slippageBps: quote.slippageBps,
    networkFeeUsd: quote.networkFeeUsd,
    route: [...quote.route],
    status,
    failureReason,
    createdAt: now,
  }
}

export class SandboxSwapTransactionAdapter {
  readonly provider: SwapProvider
  private readonly readStateImpl: AdapterOptions["readState"]
  private readonly writeStateImpl: AdapterOptions["writeState"]
  private readonly now: () => number
  private readonly generateId: (prefix: string) => string

  constructor(options: AdapterOptions) {
    this.readStateImpl = options.readState
    this.writeStateImpl = options.writeState
    this.provider = options.provider ?? new MockSwapProvider()
    this.now = options.now ?? Date.now
    this.generateId = options.generateId ?? defaultId
  }

  getAllowance(walletId: string, assetId: string) {
    const asset = getSwapAsset(assetId)
    if (asset?.isNative) return Number.POSITIVE_INFINITY
    return this.readStateImpl().allowances[allowanceKey(walletId, assetId)] ?? 0
  }

  requiresApproval(walletId: string, assetId: string, amount: number) {
    return this.getAllowance(walletId, assetId) < amount
  }

  async approve(walletId: string, assetId: string, amount: number, options: SwapExecutionOptions = {}) {
    const now = options.now ?? this.now()
    if (options.rejectApproval) {
      return {
        status: "rejected" as const,
        hash: null,
        failureReason: "User rejected approval.",
      }
    }
    if (options.failApproval) {
      return {
        status: "failed" as const,
        hash: null,
        failureReason: "Approval failed.",
      }
    }

    const state = cloneState(this.readStateImpl())
    state.allowances[allowanceKey(walletId, assetId)] = Math.max(this.getAllowance(walletId, assetId), amount)
    this.writeStateImpl(state)

    return {
      status: "approval_confirmed" as const,
      hash: `0xapprove${now.toString(16)}`,
      failureReason: null,
    }
  }

  async executeSwap(quote: SwapQuote, walletId: string, options: SwapExecutionOptions = {}) {
    const now = options.now ?? this.now()
    const transactionId = this.generateId("swap")
    const state = cloneState(this.readStateImpl())

    if (!isQuoteUsable(quote, now)) {
      const record = recordFailure(quote, walletId, "expired", "Quote expired before submission.", now, transactionId)
      this.writeStateImpl({ ...state, transactions: [record, ...state.transactions] })
      return record
    }

    if (this.requiresApproval(walletId, quote.inputAssetId, quote.inputAmount)) {
      const record = recordFailure(quote, walletId, "approval_pending", "Token approval required.", now, transactionId)
      this.writeStateImpl({ ...state, transactions: [record, ...state.transactions] })
      return record
    }

    if (options.rejectSwap) {
      const record = recordFailure(quote, walletId, "rejected", "User rejected swap.", now, transactionId)
      this.writeStateImpl({ ...state, transactions: [record, ...state.transactions] })
      return record
    }

    if (options.revertSwap) {
      const record = recordFailure(quote, walletId, "failed", "Swap transaction reverted.", now, transactionId)
      this.writeStateImpl({ ...state, transactions: [record, ...state.transactions] })
      return record
    }

    const debited = upsertWalletBalance(state.balances, walletId, quote.inputAssetId, -quote.inputAmount)
    const credited = upsertWalletBalance(debited, walletId, quote.outputAssetId, quote.estimatedOutputAmount)
    const record: SwapTransactionRecord = {
      id: transactionId,
      walletId,
      inputAssetId: quote.inputAssetId,
      outputAssetId: quote.outputAssetId,
      inputAmount: quote.inputAmount,
      outputAmount: quote.estimatedOutputAmount,
      minimumOutputAmount: quote.minimumOutputAmount,
      quoteId: quote.id,
      provider: quote.provider,
      exchangeRate: quote.exchangeRate,
      priceImpactPct: quote.priceImpactPct,
      slippageBps: quote.slippageBps,
      networkFeeUsd: quote.networkFeeUsd,
      route: [...quote.route],
      swapTransactionHash: `0xswap${now.toString(16)}`,
      status: "confirmed",
      createdAt: now,
      confirmedAt: now,
    }

    this.writeStateImpl({
      ...state,
      balances: credited,
      transactions: [record, ...state.transactions],
    })
    return record
  }
}
