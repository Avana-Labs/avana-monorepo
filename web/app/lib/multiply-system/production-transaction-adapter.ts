import type { MultiplyAction } from "@/app/lib/multiply-engine"
import type {
  MultiplySandboxActionResult,
  MultiplyTransactionAdapter,
  MultiplyTransactionIntent,
  MultiplyTransactionPreview,
} from "./contracts"

const NOT_IMPLEMENTED = "Production multiply transaction adapter is not implemented"

export type ProductionMultiplyTransactionSource = Partial<{
  previewTransaction: (intent: MultiplyTransactionIntent) => Promise<MultiplyTransactionPreview>
  executeTransaction: (intent: MultiplyTransactionIntent) => Promise<MultiplySandboxActionResult>
  now: () => number
  generateId: (prefix: string) => string
}>

function defaultId(prefix: string) {
  return `${prefix}-${Math.random().toString(36).slice(2, 10)}`
}

export class ProductionMultiplyTransactionAdapter implements MultiplyTransactionAdapter {
  readonly mode = "production" as const

  private readonly now: () => number
  private readonly generateId: (prefix: string) => string

  constructor(private readonly source: ProductionMultiplyTransactionSource = {}) {
    this.now = source.now ?? Date.now
    this.generateId = source.generateId ?? defaultId
  }

  createIntent(action: MultiplyAction): MultiplyTransactionIntent {
    return {
      id: this.generateId("intent"),
      actionType: action.type,
      walletId: action.walletId,
      marketId: action.type === "multiply" ? action.marketId : undefined,
      positionId: action.type === "multiply" ? undefined : action.positionId,
      requestedAt: this.now(),
      simulated: false,
      payload: action,
    }
  }

  async previewTransaction(intent: MultiplyTransactionIntent): Promise<MultiplyTransactionPreview> {
    if (!this.source.previewTransaction) throw new Error(NOT_IMPLEMENTED)
    return this.source.previewTransaction(intent)
  }

  async executeTransaction(intent: MultiplyTransactionIntent): Promise<MultiplySandboxActionResult> {
    if (!this.source.executeTransaction) throw new Error(NOT_IMPLEMENTED)
    return this.source.executeTransaction(intent)
  }
}
