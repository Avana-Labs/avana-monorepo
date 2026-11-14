import type { LendAction } from "@/app/lib/lend-system/model"
import type {
  LendActionResult,
  LendTransactionAdapter,
  LendTransactionIntent,
  LendTransactionPreview,
} from "./contracts"

import { TRANSACTIONS_UNAVAILABLE } from "@/app/lib/borrow-system/production-transaction-adapter"

const EMPTY_METRICS = {
  suppliedAmount: 0,
  suppliedValueUsd: 0,
  principalAmount: 0,
  interestEarned: 0,
  rewardsEarnedUsd: 0,
  totalEarnedUsd: 0,
  currentApy: 0,
}

type ProductionLendTransactionAdapterOptions = Partial<{
  previewTransaction: (intent: LendTransactionIntent) => Promise<LendTransactionPreview>
  executeTransaction: (intent: LendTransactionIntent) => Promise<LendActionResult>
  now: () => number
  generateId: (prefix: string) => string
}>

function defaultId(prefix: string) {
  return `${prefix}-${Math.random().toString(36).slice(2, 10)}`
}

export class ProductionLendTransactionAdapter implements LendTransactionAdapter {
  readonly mode = "production" as const

  private readonly now: () => number
  private readonly generateId: (prefix: string) => string

  constructor(private readonly source: ProductionLendTransactionAdapterOptions = {}) {
    this.now = source.now ?? Date.now
    this.generateId = source.generateId ?? defaultId
  }

  createIntent(action: LendAction): LendTransactionIntent {
    return {
      id: this.generateId("intent"),
      actionType: action.type,
      walletId: action.walletId,
      marketId: action.type === "claim" ? "rewards" : action.marketId,
      positionId: action.type === "withdraw" ? action.positionId : undefined,
      requestedAt: this.now(),
      simulated: false,
      payload: action,
    }
  }

  async previewTransaction(intent: LendTransactionIntent): Promise<LendTransactionPreview> {
    if (this.source.previewTransaction) return this.source.previewTransaction(intent)
    return {
      intent,
      allowed: false,
      warnings: [],
      validationErrors: [TRANSACTIONS_UNAVAILABLE],
      before: EMPTY_METRICS,
      after: EMPTY_METRICS,
    }
  }

  async executeTransaction(intent: LendTransactionIntent): Promise<LendActionResult> {
    if (!this.source.executeTransaction) throw new Error(TRANSACTIONS_UNAVAILABLE)
    return this.source.executeTransaction(intent)
  }
}
