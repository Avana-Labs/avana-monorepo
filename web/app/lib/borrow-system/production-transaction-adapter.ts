import type { BorrowAction } from "@/app/lib/borrow-system/model"
import type {
  ActionResult,
  TransactionActionType,
  TransactionAdapter,
  TransactionIntent,
  TransactionPreview,
} from "./contracts"

/** Shown wherever an action would run until the contract calls are wired. */
export const TRANSACTIONS_UNAVAILABLE = "Transactions are not available yet."

const EMPTY_METRICS = {
  collateralValueUsd6: 0n,
  borrowCapacityUsd6: 0n,
  availableBorrowCapacityUsd6: 0n,
  totalBorrowedUsd6: 0n,
  currentLtvWad: 0n,
  healthFactorWad: null,
}

export type ProductionBorrowTransactionSource = Partial<{
  previewTransaction: (intent: TransactionIntent) => Promise<TransactionPreview>
  executeTransaction: (intent: TransactionIntent) => Promise<ActionResult>
  now: () => number
  generateId: (prefix: string) => string
}>

function defaultId(prefix: string) {
  return `${prefix}-${Math.random().toString(36).slice(2, 10)}`
}

function actionType(action: BorrowAction): TransactionActionType {
  if (action.type === "supplyCollateral") return "deposit"
  if (action.type === "removeCollateral") return "withdraw"
  return action.type
}

function actionAmount(action: BorrowAction) {
  if (action.type === "removeCollateral") return action.amountUsd6 ?? 0n
  if (action.type === "liquidate") return action.repayAmountUsd6
  return action.amountUsd6
}

export class ProductionTransactionAdapter implements TransactionAdapter {
  readonly mode = "production" as const

  private readonly now: () => number
  private readonly generateId: (prefix: string) => string

  constructor(private readonly source: ProductionBorrowTransactionSource = {}) {
    this.now = source.now ?? Date.now
    this.generateId = source.generateId ?? defaultId
  }

  createIntent(action: BorrowAction): TransactionIntent {
    return {
      id: this.generateId("intent"),
      actionType: actionType(action),
      walletId: action.walletId,
      marketId: "marketId" in action ? action.marketId : undefined,
      assetId: "assetId" in action ? action.assetId : undefined,
      positionId: "positionId" in action ? action.positionId : undefined,
      debtPositionId: "debtPositionId" in action ? action.debtPositionId : undefined,
      amountUsd6: actionAmount(action),
      requestedAt: this.now(),
      simulated: false,
      payload: action,
    }
  }

  async previewTransaction(intent: TransactionIntent): Promise<TransactionPreview> {
    if (this.source.previewTransaction) return this.source.previewTransaction(intent)
    return {
      intent,
      allowed: false,
      warnings: [],
      validationErrors: [TRANSACTIONS_UNAVAILABLE],
      riskLabel: "safe",
      before: EMPTY_METRICS,
      after: EMPTY_METRICS,
    }
  }

  async executeTransaction(intent: TransactionIntent): Promise<ActionResult> {
    if (!this.source.executeTransaction) throw new Error(TRANSACTIONS_UNAVAILABLE)
    return this.source.executeTransaction(intent)
  }
}
