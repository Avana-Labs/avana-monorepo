import {
  applyLendAction,
  simulateDeposit,
  simulateWithdraw,
  type LendAction,
  type LendSystemState,
} from "@/app/lib/lend-engine"
import { getWalletBalanceForLendMarket } from "@/app/lib/lend-system/wallet-balances"
import { buildLendWalletSnapshot } from "./read-model"
import type {
  LendSandboxActionResult,
  LendTransactionAdapter,
  LendTransactionHistoryItem,
  LendTransactionIntent,
  LendTransactionPreview,
  LendTransactionResult,
} from "./contracts"

type SandboxAdapterOptions = {
  readState: () => LendSystemState
  writeState: (state: LendSystemState) => void
  persistResult?: (result: LendSandboxActionResult) => Promise<LendTransactionResult>
  now?: () => number
  generateId?: (prefix: string) => string
}

function defaultId(prefix: string) {
  return `${prefix}-${Math.random().toString(36).slice(2, 10)}`
}

function findWalletPosition(state: LendSystemState, walletId: string, marketId: string) {
  return Object.values(state.positions).find(
    (position) => position.walletId === walletId && position.marketId === marketId && position.status === "active",
  )
}

function actionWithStateWalletBalance(state: LendSystemState, action: LendAction): LendAction {
  if (action.type !== "deposit") return action
  const market = state.markets[action.marketId]
  if (!market) return action

  return {
    ...action,
    walletBalance: getWalletBalanceForLendMarket(state, action.walletId, market),
  }
}

function toPreview(state: LendSystemState, action: LendAction, intent: LendTransactionIntent): LendTransactionPreview {
  if (action.type === "deposit") {
    const market = state.markets[action.marketId]
    if (!market) throw new Error(`Unknown market ${action.marketId}`)
    const existing = findWalletPosition(state, action.walletId, action.marketId)
    const simulation = simulateDeposit({
      market,
      position: existing,
      depositAmount: action.depositAmount,
      walletBalance: action.walletBalance,
      now: state.now,
    })

    return {
      intent,
      allowed: simulation.validation.allowed,
      warnings: simulation.validation.warnings,
      validationErrors: simulation.validation.errors,
      before: {
        suppliedAmount: simulation.before.suppliedAmount,
        suppliedValueUsd: simulation.before.suppliedValueUsd,
        principalAmount: simulation.before.principalAmount,
        interestEarned: simulation.before.interestEarned,
        rewardsEarnedUsd: simulation.before.rewardsEarnedUsd,
        totalEarnedUsd: simulation.before.totalEarnedUsd,
        currentApy: simulation.market.totalApy,
      },
      after: {
        suppliedAmount: simulation.after.suppliedAmount,
        suppliedValueUsd: simulation.after.suppliedValueUsd,
        principalAmount: simulation.after.principalAmount,
        interestEarned: simulation.after.interestEarned,
        rewardsEarnedUsd: simulation.after.rewardsEarnedUsd,
        totalEarnedUsd: simulation.after.totalEarnedUsd,
        currentApy: simulation.market.totalApy,
      },
    }
  }

  if (action.type === "claim") {
    const walletSnapshot = buildLendWalletSnapshot(action.walletId, state, [])
    const before = walletSnapshot.metrics
    const claimableUsd = before.rewardsEarnedUsd

    return {
      intent,
      allowed: claimableUsd > 0,
      warnings: [],
      validationErrors: claimableUsd > 0 ? [] : ["No lend rewards are available to claim."],
      before: {
        suppliedAmount: before.suppliedAmount,
        suppliedValueUsd: before.suppliedValueUsd,
        principalAmount: before.principalAmount,
        interestEarned: before.interestEarned,
        rewardsEarnedUsd: before.rewardsEarnedUsd,
        totalEarnedUsd: before.totalEarnedUsd,
        currentApy: before.currentApy,
      },
      after: {
        suppliedAmount: before.suppliedAmount,
        suppliedValueUsd: before.suppliedValueUsd,
        principalAmount: before.principalAmount,
        interestEarned: before.interestEarned,
        rewardsEarnedUsd: 0,
        totalEarnedUsd: before.totalEarnedUsd - claimableUsd,
        currentApy: before.currentApy,
      },
    }
  }

  const position = state.positions[action.positionId]
  if (!position) throw new Error(`Unknown position ${action.positionId}`)
  const market = state.markets[action.marketId]
  if (!market) throw new Error(`Unknown market ${action.marketId}`)
  const simulation = simulateWithdraw({
    market,
    position,
    withdrawAmount: action.withdrawAmount,
    now: state.now,
  })

  return {
    intent,
    allowed: simulation.validation.allowed,
    warnings: simulation.validation.warnings,
    validationErrors: simulation.validation.errors,
    before: {
      suppliedAmount: simulation.before.suppliedAmount,
      suppliedValueUsd: simulation.before.suppliedValueUsd,
      principalAmount: simulation.before.principalAmount,
      interestEarned: simulation.before.interestEarned,
      rewardsEarnedUsd: simulation.before.rewardsEarnedUsd,
      totalEarnedUsd: simulation.before.totalEarnedUsd,
      currentApy: simulation.market.totalApy,
    },
    after: {
      suppliedAmount: simulation.after.suppliedAmount,
      suppliedValueUsd: simulation.after.suppliedValueUsd,
      principalAmount: simulation.after.principalAmount,
      interestEarned: simulation.after.interestEarned,
      rewardsEarnedUsd: simulation.after.rewardsEarnedUsd,
      totalEarnedUsd: simulation.after.totalEarnedUsd,
      currentApy: simulation.market.totalApy,
    },
    maxWithdrawable: simulation.withdrawal.maxWithdrawable,
  }
}

export class SandboxLendTransactionAdapter implements LendTransactionAdapter {
  readonly mode = "sandbox" as const
  private readonly readStateImpl: SandboxAdapterOptions["readState"]
  private readonly writeStateImpl: SandboxAdapterOptions["writeState"]
  private readonly persistResult?: SandboxAdapterOptions["persistResult"]
  private readonly now: () => number
  private readonly generateId: (prefix: string) => string
  private readonly previewCache = new Map<string, LendTransactionPreview>()

  constructor(options: SandboxAdapterOptions) {
    this.readStateImpl = options.readState
    this.writeStateImpl = options.writeState
    this.persistResult = options.persistResult
    this.now = options.now ?? Date.now
    this.generateId = options.generateId ?? defaultId
  }

  createIntent(action: LendAction): LendTransactionIntent {
    return {
      id: this.generateId("intent"),
      actionType: action.type,
      walletId: action.walletId,
      marketId: action.type === "claim" ? "rewards" : action.marketId,
      positionId: action.type === "withdraw" ? action.positionId : undefined,
      requestedAt: this.now(),
      simulated: true,
      payload: action,
    }
  }

  async previewTransaction(intent: LendTransactionIntent): Promise<LendTransactionPreview> {
    const cached = this.previewCache.get(intent.id)
    if (cached) return cached
    const action = intent.payload
    if (!action) throw new Error("Missing lend action payload")
    const state = this.readStateImpl()
    const preview = toPreview(state, actionWithStateWalletBalance(state, action), intent)
    this.previewCache.set(intent.id, preview)
    return preview
  }

  async executeTransaction(intent: LendTransactionIntent): Promise<LendSandboxActionResult> {
    const state = this.readStateImpl()
    const action = intent.payload ? actionWithStateWalletBalance(state, intent.payload) : null
    const preview = action ? toPreview(state, action, intent) : await this.previewTransaction(intent)
    this.previewCache.set(intent.id, preview)

    if (!action || !preview.allowed) {
      // Mirror borrow/multiply: record the failure so it appears in activity
      // rather than throwing before anything is persisted. State is left
      // unchanged so no phantom position is created.
      return this.finalizeFailure(
        intent,
        preview,
        state,
        preview.validationErrors[0] ?? "Lend transaction is not allowed",
      )
    }

    const positionId =
      action.type === "withdraw"
        ? action.positionId
        : action.type === "claim"
          ? `${action.walletId}:rewards`
          : (findWalletPosition(state, action.walletId, action.marketId)?.positionId ??
            `${action.walletId}:${action.marketId}`)
    const transactionId = this.generateId("tx")
    const nextState = applyLendAction(state, action, { positionId, transactionId })
    // The engine may sweep a sub-cent remainder into a full withdraw and record the swept total
    // as the transaction amount; surface THAT (not the pre-sweep requested amount) so history
    // reconciles with the position closing to zero.
    const engineTxAmount = nextState.transactions.find((tx) => tx.id === transactionId)?.amount

    const localReceipt = {
      id: transactionId,
      hash: `sim_lend_${transactionId}`,
      status: "success" as const,
      actionType: action.type,
      simulated: true as const,
      timestamp: this.now(),
    }

    const historyItem: LendTransactionHistoryItem = {
      id: transactionId,
      intentId: intent.id,
      walletId: action.walletId,
      marketId: action.type === "claim" ? "rewards" : action.marketId,
      positionId,
      kind: action.type,
      status: "success",
      asset: action.type === "claim" ? "Rewards" : (state.markets[action.marketId]?.asset.symbol ?? ""),
      amount:
        action.type === "deposit"
          ? action.depositAmount
          : action.type === "withdraw"
            ? (engineTxAmount ?? action.withdrawAmount)
            : preview.before.rewardsEarnedUsd,
      simulated: true,
      timestamp: localReceipt.timestamp,
      hash: localReceipt.hash,
    }

    const localResult: LendSandboxActionResult = {
      preview,
      receipt: localReceipt,
      historyItem,
      state: nextState,
    }
    const persisted = this.persistResult ? await this.persistResult(localResult) : localReceipt
    if (persisted.status === "idle") throw new Error("Convex returned an invalid idle transaction receipt")
    const receipt = { ...localReceipt, ...persisted, actionType: localReceipt.actionType }
    const persistedResult = {
      ...localResult,
      receipt,
      historyItem: {
        ...historyItem,
        id: persisted.id,
        hash: persisted.hash,
        status: persisted.status,
        timestamp: persisted.timestamp,
      },
    }
    this.writeStateImpl(nextState)
    return persistedResult
  }

  /**
   * Record a FAILED lend action (deposit/withdraw/claim) without mutating state,
   * mirroring the borrow/multiply adapters so a blocked attempt still shows up in
   * activity. Persisting the failure is best-effort — if the backend is absent or
   * throws, the local failed result is returned so nothing is lost.
   */
  private async finalizeFailure(
    intent: LendTransactionIntent,
    preview: LendTransactionPreview,
    state: LendSystemState,
    error: string,
  ): Promise<LendSandboxActionResult> {
    const timestamp = this.now()
    const receipt: LendTransactionResult = {
      id: this.generateId("tx"),
      hash: this.generateId("sim_lend"),
      status: "failed",
      actionType: intent.actionType,
      simulated: true,
      timestamp,
      error,
    }
    const historyItem: LendTransactionHistoryItem = {
      id: receipt.id,
      intentId: intent.id,
      walletId: intent.walletId,
      marketId: intent.marketId,
      positionId: intent.positionId,
      kind: intent.actionType,
      status: "failed",
      asset: intent.actionType === "claim" ? "Rewards" : (state.markets[intent.marketId]?.asset.symbol ?? ""),
      amount: 0,
      simulated: true,
      timestamp,
      hash: receipt.hash,
    }
    const localResult: LendSandboxActionResult = { preview, receipt, historyItem, state }

    if (!this.persistResult) return localResult
    try {
      const persisted = await this.persistResult(localResult)
      return {
        ...localResult,
        receipt: { ...receipt, ...persisted, actionType: receipt.actionType },
        historyItem: {
          ...historyItem,
          id: persisted.id,
          hash: persisted.hash,
          status: persisted.status,
          timestamp: persisted.timestamp,
        },
      }
    } catch {
      // Recording a failure is best-effort; keep the local failed result.
      return localResult
    }
  }
}
