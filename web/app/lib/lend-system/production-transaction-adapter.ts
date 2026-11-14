import type { LendAction } from "@/app/lib/lend-engine"
import type {
  LendSandboxActionResult,
  LendTransactionAdapter,
  LendTransactionIntent,
  LendTransactionPreview,
} from "./contracts"

const NOT_IMPLEMENTED = "Production lend transaction adapter is not implemented"

type ProductionLendTransactionAdapterOptions = Partial<{
  previewTransaction: (intent: LendTransactionIntent) => Promise<LendTransactionPreview>
  executeTransaction: (intent: LendTransactionIntent) => Promise<LendSandboxActionResult>
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
    if (!this.source.previewTransaction) throw new Error(NOT_IMPLEMENTED)
    return this.source.previewTransaction(intent)
  }

  async executeTransaction(intent: LendTransactionIntent): Promise<LendSandboxActionResult> {
    if (!this.source.executeTransaction) throw new Error(NOT_IMPLEMENTED)
    return this.source.executeTransaction(intent)
  }
}
