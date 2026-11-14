import {
  applyBorrowAction,
  simulateBorrow,
  simulateClaim,
  simulateDeposit,
  simulateLiquidation,
  simulateRepay,
  simulateWithdraw,
  type BorrowAction,
  type BorrowSystemState,
} from "@/app/lib/credit-engine"
import { resolveBorrowAssetId } from "@/app/lib/action-system/resolve-borrow-context"
import type {
  SandboxActionResult,
  TransactionActionType,
  TransactionAdapter,
  TransactionHistoryItem,
  TransactionIntent,
  TransactionPreview,
} from "./contracts"
import { applyBorrowLiquidityDeltasToEngineState, type DeltaMap } from "@/app/lib/market-liquidity/apply"

type SandboxAdapterOptions = {
  readState: () => BorrowSystemState
  writeState: (state: BorrowSystemState) => void
  persistResult?: (result: SandboxActionResult) => Promise<{
    id: string
    hash: string
    status: "success" | "failed" | "pending"
    simulated: boolean
    timestamp: number
  }>
  getLiquidityDeltas?: () => DeltaMap
  now?: () => number
  generateId?: (prefix: string) => string
}

function defaultId(prefix: string) {
  return `${prefix}-${Math.random().toString(36).slice(2, 10)}`
}

function normalizeActionType(action: BorrowAction): TransactionActionType {
  switch (action.type) {
    case "supplyCollateral":
      return "deposit"
    case "removeCollateral":
      return "withdraw"
    case "liquidate":
      return "liquidate"
    case "repay":
      return "repay"
    case "borrow":
      return "borrow"
    case "claim":
      return "claim"
  }
}

function toIntentAmount(action: BorrowAction) {
  switch (action.type) {
    case "removeCollateral":
      return action.amountUsd6 ?? 0n
    case "liquidate":
      return action.repayAmountUsd6
    default:
      return action.amountUsd6
  }
}

function executedAmountFromPreview(action: BorrowAction, preview: TransactionPreview) {
  if (action.type === "removeCollateral") {
    const delta = preview.before.collateralValueUsd6 - preview.after.collateralValueUsd6
    return delta > 0n ? delta : 0n
  }
  return toIntentAmount(action)
}

function normalizeBorrowAction(state: BorrowSystemState, action: BorrowAction): BorrowAction {
  if (action.type !== "borrow") return action

  const marketId = action.marketId
  const resolvedAssetId = resolveBorrowAssetId(state, action.assetId, marketId)
  if (!resolvedAssetId || resolvedAssetId === action.assetId) return action

  return {
    ...action,
    assetId: resolvedAssetId,
  }
}

function toPreview(
  state: BorrowSystemState,
  action: BorrowAction,
  intent: TransactionIntent,
  getLiquidityDeltas?: () => DeltaMap,
): TransactionPreview {
  const preparedState =
    action.type === "borrow" && getLiquidityDeltas
      ? applyBorrowLiquidityDeltasToEngineState(state, getLiquidityDeltas())
      : state
  const simulation =
    action.type === "supplyCollateral"
      ? simulateDeposit(preparedState, action)
      : action.type === "borrow"
        ? simulateBorrow(preparedState, action)
        : action.type === "repay"
          ? simulateRepay(state, action)
          : action.type === "removeCollateral"
            ? simulateWithdraw(state, action)
            : action.type === "claim"
              ? simulateClaim(state, action)
              : simulateLiquidation(state, action)

  return {
    intent,
    allowed: simulation.allowed,
    warnings: simulation.warnings,
    validationErrors: simulation.validationErrors,
    riskLabel: simulation.riskLabel,
    before: simulation.before.metrics,
    after: simulation.after.metrics,
  }
}

export class SandboxTransactionAdapter implements TransactionAdapter {
  readonly mode = "sandbox" as const
  private readonly readStateImpl: SandboxAdapterOptions["readState"]
  private readonly writeStateImpl: SandboxAdapterOptions["writeState"]
  private readonly persistResult?: SandboxAdapterOptions["persistResult"]
  private readonly getLiquidityDeltas?: SandboxAdapterOptions["getLiquidityDeltas"]
  private readonly now: () => number
  private readonly generateId: (prefix: string) => string
  private readonly seed: BorrowSystemState
  private readonly previewCache = new Map<string, TransactionPreview>()
  private readonly previewStateByIntent = new Map<string, BorrowSystemState>()

  constructor(options: SandboxAdapterOptions) {
    this.readStateImpl = options.readState
    this.writeStateImpl = options.writeState
    this.persistResult = options.persistResult
    this.getLiquidityDeltas = options.getLiquidityDeltas
    this.now = options.now ?? Date.now
    this.generateId = options.generateId ?? defaultId
    this.seed = options.readState()
  }

  createIntent(action: BorrowAction): TransactionIntent {
    const state = this.readStateImpl()
    const normalized = normalizeBorrowAction(state, action)
    const debtAssetId =
      normalized.type === "repay"
        ? state.accounts[normalized.walletId]?.debtPositions.find(
            (position) => position.id === normalized.debtPositionId,
          )?.assetId
        : undefined
    return {
      id: this.generateId("intent"),
      actionType: normalizeActionType(normalized),
      walletId: normalized.walletId,
      marketId: "marketId" in normalized ? normalized.marketId : undefined,
      assetId: "assetId" in normalized ? (normalized.assetId ?? debtAssetId) : debtAssetId,
      positionId: "positionId" in normalized ? normalized.positionId : undefined,
      debtPositionId: "debtPositionId" in normalized ? normalized.debtPositionId : undefined,
      amountUsd6: toIntentAmount(normalized),
      requestedAt: this.now(),
      simulated: true,
      payload: normalized,
    }
  }

  async previewTransaction(intent: TransactionIntent): Promise<TransactionPreview> {
    const cached = this.previewCache.get(intent.id)
    if (cached) {
      return cached
    }

    const action = intent.payload
    if (!action) {
      throw new Error("Sandbox transaction intent is missing its borrow action payload")
    }
    const state = this.readStateImpl()
    const preview = toPreview(state, action, intent, this.getLiquidityDeltas)
    this.previewCache.set(intent.id, preview)
    this.previewStateByIntent.set(intent.id, state)
    return preview
  }

  async executeTransaction(intent: TransactionIntent): Promise<SandboxActionResult> {
    const action = intent.payload
    if (!action) {
      throw new Error("Sandbox transaction intent is missing its borrow action payload")
    }

    const current = this.readStateImpl()
    const previewState = this.previewStateByIntent.get(intent.id)
    if (previewState && previewState !== current) {
      this.previewCache.delete(intent.id)
      this.previewStateByIntent.delete(intent.id)
      throw new Error(
        "Quote is stale because the account or market changed. Review the refreshed quote before submitting.",
      )
    }
    const preview = await this.previewTransaction(intent)
    const timestamp = this.now()

    if (action.type === "liquidate") {
      const receipt = {
        id: this.generateId("receipt"),
        hash: this.generateId("sim"),
        status: "failed" as const,
        actionType: intent.actionType,
        simulated: true,
        timestamp,
        error: "Liquidation is preview-only in sandbox mode",
      }
      const historyItem: TransactionHistoryItem = {
        id: this.generateId("history"),
        intentId: intent.id,
        walletId: intent.walletId,
        marketId: intent.marketId,
        assetId: intent.assetId,
        kind: intent.actionType,
        status: "failed",
        requestedAmountUsd6: intent.amountUsd6,
        executedAmountUsd6: 0n,
        simulated: true,
        timestamp,
        hash: receipt.hash,
      }

      return this.finalize(
        {
          preview,
          receipt,
          result: receipt,
          historyItem,
          state: current,
        },
        true,
      )
    }

    if (!preview.allowed) {
      const receipt = {
        id: this.generateId("receipt"),
        hash: this.generateId("sim"),
        status: "failed" as const,
        actionType: intent.actionType,
        simulated: true,
        timestamp,
        error: preview.validationErrors[0],
      }
      const historyItem: TransactionHistoryItem = {
        id: this.generateId("history"),
        intentId: intent.id,
        walletId: intent.walletId,
        marketId: intent.marketId,
        assetId: intent.assetId,
        kind: intent.actionType,
        status: "failed",
        requestedAmountUsd6: intent.amountUsd6,
        executedAmountUsd6: 0n,
        simulated: true,
        timestamp,
        hash: receipt.hash,
      }

      return this.finalize(
        {
          preview,
          receipt,
          result: receipt,
          historyItem,
          state: current,
        },
        true,
      )
    }

    const nextState = applyBorrowAction(current, {
      ...action,
      at: timestamp,
    } as BorrowAction)
    const appliedTransaction = nextState.transactions.at(-1)
    const localReceipt = {
      id: this.generateId("receipt"),
      hash: this.generateId("sim"),
      status: "success" as const,
      actionType: intent.actionType,
      simulated: true,
      timestamp,
    }
    const historyItem: TransactionHistoryItem = {
      id: this.generateId("history"),
      intentId: intent.id,
      walletId: intent.walletId,
      marketId: intent.marketId ?? appliedTransaction?.marketId,
      assetId: intent.assetId,
      kind: intent.actionType,
      status: "success",
      requestedAmountUsd6: intent.amountUsd6,
      executedAmountUsd6: executedAmountFromPreview(action, preview),
      simulated: true,
      timestamp,
      hash: localReceipt.hash,
    }

    const localResult: SandboxActionResult = {
      preview,
      receipt: localReceipt,
      result: localReceipt,
      historyItem,
      state: nextState,
    }
    const finalized = await this.finalize(localResult)
    this.writeStateImpl(nextState)
    return finalized
  }

  /**
   * Persist a result through the configured backend (Convex when authed) and fold
   * the persisted ids/status back into the receipt + history item. Used for BOTH
   * successful and failed actions so a rejected/liquidation attempt is still
   * recorded (and survives reload), not silently dropped. When there's no backend
   * (local sandbox) or persistence throws, the local result is returned unchanged
   * so nothing is lost.
   */
  private async finalize(localResult: SandboxActionResult, bestEffort = false): Promise<SandboxActionResult> {
    if (!this.persistResult) return localResult
    try {
      const persisted = await this.persistResult(localResult)
      const receipt = { ...localResult.receipt, ...persisted }
      return {
        ...localResult,
        receipt,
        result: receipt,
        historyItem: {
          ...localResult.historyItem,
          id: persisted.id,
          hash: persisted.hash,
          status: persisted.status,
          timestamp: persisted.timestamp,
        },
      }
    } catch (error) {
      // Recording a FAILED action is best-effort — keep the local receipt so the
      // attempt still shows in-session. A SUCCESS that can't be saved must surface.
      if (bestEffort) return localResult
      throw error
    }
  }

  resetSandboxState() {
    this.writeStateImpl(this.seed)
  }
}
