import {
  applyMultiplyAction,
  revalueMultiplyPosition,
  simulateDeleverage,
  simulateMultiply,
  type MultiplyAction,
  type MultiplySystemState,
} from "@/app/lib/multiply-engine"
import { calculateNetApy } from "@/app/lib/multiply-engine/formulas"
import type { MultiplyMarketRecord } from "@/app/lib/multiply-engine/types"
import type {
  MultiplySandboxActionResult,
  MultiplyTransactionAdapter,
  MultiplyTransactionHistoryItem,
  MultiplyTransactionIntent,
  MultiplyTransactionPreview,
  MultiplyTransactionResult,
} from "./contracts"

type SandboxAdapterOptions = {
  readState: () => MultiplySystemState
  writeState: (state: MultiplySystemState) => void
  persistResult?: (result: MultiplySandboxActionResult) => Promise<MultiplyTransactionResult>
  now?: () => number
  generateId?: (prefix: string) => string
}

function defaultId(prefix: string) {
  return `${prefix}-${Math.random().toString(36).slice(2, 10)}`
}

function netApyForPositionState(
  market: MultiplyMarketRecord,
  collateralValueUsd: number,
  debtValueUsd: number,
  fallbackSupplyApy = true,
): number {
  if (collateralValueUsd <= 0 && debtValueUsd <= 0) {
    return fallbackSupplyApy ? market.economics.supplyApy : 0
  }
  const equityUsd = Math.max(1, collateralValueUsd - debtValueUsd)
  return calculateNetApy({
    supplyApy: market.economics.supplyApy,
    borrowApy: market.economics.borrowApy,
    finalCollateralValueUsd: collateralValueUsd,
    debtValueUsd,
    initialCollateralValueUsd: equityUsd,
  })
}

/**
 * The USD amount recorded on an activity row for a multiply action.
 *  - multiply: the collateral added to the position (position growth).
 *  - close: the equity returned to the user (collateral withdrawn minus debt repaid).
 *  - deleverage: the size of the unwind, i.e. the debt repaid. A reduce sells
 *    collateral to repay debt without returning cash, so its equity delta is ~0 —
 *    recording that would show a bogus "$0"/"-$0.01" row. The debt repaid is the
 *    real, nonzero magnitude of the transaction.
 */
function recordedAmountUsd(actionType: MultiplyAction["type"], preview: MultiplyTransactionPreview): number {
  if (actionType === "multiply") {
    // The equity the wallet puts in (what the activity feed shows leaving the wallet), matching
    // close, which records the equity returned. The exposure added read -$207 for $138 paid.
    return Math.max(
      0,
      preview.after.collateralValueUsd -
        preview.after.debtValueUsd -
        (preview.before.collateralValueUsd - preview.before.debtValueUsd),
    )
  }
  if (actionType === "deleverage") {
    return Math.max(0, preview.before.debtValueUsd - preview.after.debtValueUsd)
  }
  // close
  return Math.max(
    0,
    preview.before.collateralValueUsd -
      preview.after.collateralValueUsd -
      (preview.before.debtValueUsd - preview.after.debtValueUsd),
  )
}

function multiplyRiskLabel(simulation: ReturnType<typeof simulateMultiply>): "danger" | "safe" | "warning" {
  if (!simulation.validation.allowed) return "danger"
  const healthFactor = simulation.after.healthFactor
  if (healthFactor !== "infinity" && healthFactor < 1.05) return "danger"
  if (simulation.validation.warnings.length > 0) return "warning"
  return "safe"
}

function deleverageRiskLabel(simulation: ReturnType<typeof simulateDeleverage>): "danger" | "safe" | "warning" {
  if (!simulation.validation.allowed) return "danger"
  const healthFactor = simulation.after.healthFactor
  if (healthFactor !== "infinity" && healthFactor < 1.05) return "danger"
  if (simulation.validation.warnings.length > 0) return "warning"
  return "safe"
}

function toPreview(
  state: MultiplySystemState,
  action: MultiplyAction,
  intent: MultiplyTransactionIntent,
): MultiplyTransactionPreview {
  if (action.type === "multiply") {
    const market = state.markets[action.marketId]
    if (!market) throw new Error(`Unknown market ${action.marketId}`)
    const existing = Object.values(state.positions).find(
      (position) => position.walletId === action.walletId && position.marketId === action.marketId,
    )
    const simulation = simulateMultiply({
      market,
      collateralAmount: action.collateralAmount,
      selectedMultiplier: action.selectedMultiplier,
      existingPosition: existing,
      collateralPriceOverrideUsd: action.collateralPriceUsd,
      collateralPriceStale: action.collateralPriceStale,
    })

    return {
      intent,
      allowed: simulation.validation.allowed,
      warnings: simulation.validation.warnings,
      validationErrors: simulation.validation.errors,
      riskLabel: multiplyRiskLabel(simulation),
      before: {
        collateralValueUsd: simulation.before.collateralValueUsd,
        debtValueUsd: simulation.before.debtValueUsd,
        multiplier: simulation.before.multiplier,
        ltv: simulation.before.ltv,
        healthFactor: simulation.before.healthFactor,
        netApy: netApyForPositionState(market, simulation.before.collateralValueUsd, simulation.before.debtValueUsd),
      },
      after: {
        collateralValueUsd: simulation.after.collateralValueUsd,
        debtValueUsd: simulation.after.debtValueUsd,
        multiplier: simulation.after.multiplier,
        ltv: simulation.after.ltv,
        healthFactor: simulation.after.healthFactor,
        netApy: simulation.economics.netApy,
      },
      simulationSummary: {
        liquidationPrice: simulation.after.liquidationPrice,
        priceImpactPct: simulation.economics.priceImpactPct,
        maxLeverageApy: simulation.economics.maxLeverageApy,
        loopCount: simulation.loopCount,
      },
    }
  }

  const position = state.positions[action.positionId]
  if (!position) throw new Error(`Unknown position ${action.positionId}`)
  const market = state.markets[position.marketId]
  if (!market) throw new Error(`Unknown market ${position.marketId}`)

  if (action.type === "close") {
    // Reprice at the live collateral price before reading it — see simulateMultiply's
    // repricedExisting. The stored position can still be at a stale catalog fixture price.
    const repriced = revalueMultiplyPosition(position, market, action.collateralPriceUsd)
    // A full exit is always allowed: repay remaining debt, withdraw collateral,
    // and remove the position. The "after" state is the empty (closed) position.
    return {
      intent,
      allowed: true,
      warnings: [],
      validationErrors: [],
      riskLabel: "safe",
      before: {
        collateralValueUsd: repriced.collateralValueUsd,
        debtValueUsd: repriced.debtValueUsd,
        multiplier: repriced.multiplier,
        ltv: repriced.ltv,
        healthFactor: repriced.healthFactor,
        netApy: netApyForPositionState(market, repriced.collateralValueUsd, repriced.debtValueUsd, false),
      },
      after: {
        collateralValueUsd: 0,
        debtValueUsd: 0,
        multiplier: 1,
        ltv: 0,
        healthFactor: "infinity",
        netApy: 0,
      },
      simulationSummary: {
        liquidationPrice: null,
        priceImpactPct: 0,
      },
    }
  }

  const simulation = simulateDeleverage({
    market,
    position,
    targetMultiplier: action.targetMultiplier,
    repayAmountUsd: action.type === "deleverage" ? action.repayAmountUsd : undefined,
    collateralPriceOverrideUsd: action.type === "deleverage" ? action.collateralPriceUsd : undefined,
  })

  return {
    intent,
    allowed: simulation.validation.allowed,
    warnings: simulation.validation.warnings,
    validationErrors: simulation.validation.errors,
    riskLabel: deleverageRiskLabel(simulation),
    before: {
      collateralValueUsd: simulation.before.collateralValueUsd,
      debtValueUsd: simulation.before.debtValueUsd,
      multiplier: simulation.before.multiplier,
      ltv: simulation.before.ltv,
      healthFactor: simulation.before.healthFactor,
      netApy: netApyForPositionState(
        market,
        simulation.before.collateralValueUsd,
        simulation.before.debtValueUsd,
        false,
      ),
    },
    after: {
      collateralValueUsd: simulation.after.collateralValueUsd,
      debtValueUsd: simulation.after.debtValueUsd,
      multiplier: simulation.after.multiplier,
      ltv: simulation.after.ltv,
      healthFactor: simulation.after.healthFactor,
      netApy: simulation.economics.netApy,
    },
    simulationSummary: {
      liquidationPrice: simulation.after.liquidationPrice,
      priceImpactPct: simulation.economics.priceImpactPct,
    },
  }
}

export class SandboxMultiplyTransactionAdapter implements MultiplyTransactionAdapter {
  readonly mode = "sandbox" as const
  private readonly readStateImpl: SandboxAdapterOptions["readState"]
  private readonly writeStateImpl: SandboxAdapterOptions["writeState"]
  private readonly persistResult?: SandboxAdapterOptions["persistResult"]
  private readonly now: () => number
  private readonly generateId: (prefix: string) => string
  private readonly previewCache = new Map<string, MultiplyTransactionPreview>()

  constructor(options: SandboxAdapterOptions) {
    this.readStateImpl = options.readState
    this.writeStateImpl = options.writeState
    this.persistResult = options.persistResult
    this.now = options.now ?? Date.now
    this.generateId = options.generateId ?? defaultId
  }

  createIntent(action: MultiplyAction): MultiplyTransactionIntent {
    return {
      id: this.generateId("intent"),
      actionType: action.type,
      walletId: action.walletId,
      marketId: action.type === "multiply" ? action.marketId : undefined,
      positionId: action.type === "multiply" ? undefined : action.positionId,
      requestedAt: this.now(),
      simulated: true,
      payload: action,
    }
  }

  async previewTransaction(intent: MultiplyTransactionIntent): Promise<MultiplyTransactionPreview> {
    const action = intent.payload
    if (!action) throw new Error("Multiply transaction intent is missing its action payload")

    return toPreview(this.readStateImpl(), action, intent)
  }

  async executeTransaction(intent: MultiplyTransactionIntent): Promise<MultiplySandboxActionResult> {
    const preview = await this.previewTransaction(intent)
    const action = intent.payload
    if (!action) throw new Error("Multiply transaction intent is missing its action payload")

    if (!preview.allowed) {
      const receipt = {
        id: this.generateId("receipt"),
        hash: `0xsim${Math.random().toString(16).slice(2, 10)}`,
        status: "failed" as const,
        actionType: intent.actionType,
        simulated: true,
        timestamp: this.now(),
        error: preview.validationErrors[0] ?? "Action blocked",
      }
      const historyItem: MultiplyTransactionHistoryItem = {
        id: receipt.id,
        intentId: intent.id,
        walletId: intent.walletId,
        marketId: intent.marketId,
        positionId: intent.positionId,
        kind: intent.actionType,
        status: "failed",
        amountUsd: recordedAmountUsd(action.type, preview),
        multiplierBefore: preview.before.multiplier,
        multiplierAfter: preview.after.multiplier,
        simulated: true,
        timestamp: receipt.timestamp,
        hash: receipt.hash,
      }
      return this.finalize(
        {
          preview,
          receipt,
          historyItem,
          state: this.readStateImpl(),
        },
        true,
      )
    }

    const priorState = this.readStateImpl()
    // Capture the market id before applying the action: a close removes the position
    // from state, so it cannot be resolved from the post-action positions map.
    const resolvedMarketId =
      action.type === "multiply" ? action.marketId : priorState.positions[action.positionId]?.marketId
    const nextState = applyMultiplyAction(priorState, { ...action, at: this.now() })

    const localReceipt = {
      id: this.generateId("receipt"),
      hash: `0xsim${Math.random().toString(16).slice(2, 10)}`,
      status: "success" as const,
      actionType: intent.actionType,
      simulated: true,
      timestamp: this.now(),
    }

    const historyItem: MultiplyTransactionHistoryItem = {
      id: localReceipt.id,
      intentId: intent.id,
      walletId: intent.walletId,
      marketId: intent.marketId ?? resolvedMarketId,
      positionId: intent.positionId,
      kind: intent.actionType,
      status: "success",
      amountUsd: recordedAmountUsd(action.type, preview),
      multiplierBefore: preview.before.multiplier,
      multiplierAfter: preview.after.multiplier,
      simulated: true,
      timestamp: localReceipt.timestamp,
      hash: localReceipt.hash,
    }

    const localResult: MultiplySandboxActionResult = {
      preview,
      receipt: localReceipt,
      historyItem,
      state: nextState,
    }
    const finalized = await this.finalize(localResult)
    this.writeStateImpl(nextState)
    return finalized
  }

  /**
   * Persist a result (Convex when authed) and fold the ids/status back in. Routed
   * for BOTH successful and failed actions so a rejected multiply/deleverage is
   * recorded and survives reload. A SUCCESS persistence failure surfaces; a FAILED
   * one is best-effort (keep the local receipt). No-op without a backend.
   */
  private async finalize(
    localResult: MultiplySandboxActionResult,
    bestEffort = false,
  ): Promise<MultiplySandboxActionResult> {
    if (!this.persistResult) return localResult
    try {
      const persisted = await this.persistResult(localResult)
      if (persisted.status === "idle") {
        if (bestEffort) return localResult
        throw new Error("Convex returned an invalid idle transaction receipt")
      }
      const receipt = { ...localResult.receipt, ...persisted, actionType: localResult.receipt.actionType }
      return {
        ...localResult,
        receipt,
        historyItem: {
          ...localResult.historyItem,
          id: persisted.id,
          hash: persisted.hash,
          status: persisted.status,
          timestamp: persisted.timestamp,
        },
      }
    } catch (error) {
      if (bestEffort) return localResult
      throw error
    }
  }
}
