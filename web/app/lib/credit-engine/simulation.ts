import { applyBorrowAction } from "./actions"
import {
  calculateBorrowCapacityUsd6,
  calculateCreditMetrics,
  calculateCurrentLtvWad,
  calculateHealthFactorWad,
  calculateSpokeCreditMetrics,
} from "./metrics"
import type { BorrowAction, BorrowSpokeId, BorrowSystemState } from "./types"
import { calculateCollateralValueUsd6, currentCollateralValueUsd6 } from "./valuation"

export type SimulationRiskLabel = "safe" | "warning" | "danger"

type SimulationMetrics = {
  collateralValueUsd6: bigint
  borrowCapacityUsd6: bigint
  availableBorrowCapacityUsd6: bigint
  totalBorrowedUsd6: bigint
  currentLtvWad: bigint
  healthFactorWad: bigint | null
}

export type SimulationSnapshot = {
  state: BorrowSystemState
  metrics: SimulationMetrics
}

export type BorrowSimulationResult = {
  actionType: BorrowAction["type"]
  allowed: boolean
  warnings: string[]
  validationErrors: string[]
  riskLabel: SimulationRiskLabel
  before: SimulationSnapshot
  after: SimulationSnapshot
}

function calculateSpokeCollateralValueUsd6(state: BorrowSystemState, walletId: string, spokeId: BorrowSpokeId) {
  const account = state.accounts[walletId]
  if (!account) throw new Error(`Unknown wallet ${walletId}`)
  return account.collateralPositions.reduce((sum, position) => {
    const market = state.markets[position.marketId]
    if (!market || !position.collateralEnabled || market.spokeId !== spokeId) return sum
    return sum + currentCollateralValueUsd6(position, market)
  }, 0n)
}

function snapshot(state: BorrowSystemState, walletId: string, spokeId?: BorrowSpokeId): SimulationSnapshot {
  const metrics = spokeId
    ? calculateSpokeCreditMetrics(state, walletId, spokeId)
    : calculateCreditMetrics(state, walletId)
  return {
    state,
    metrics: {
      collateralValueUsd6: spokeId
        ? calculateSpokeCollateralValueUsd6(state, walletId, spokeId)
        : calculateCollateralValueUsd6(state, walletId),
      borrowCapacityUsd6: calculateBorrowCapacityUsd6(state, walletId, spokeId),
      availableBorrowCapacityUsd6: metrics.availableCreditUsd6,
      totalBorrowedUsd6: metrics.totalBorrowedUsd6,
      currentLtvWad: calculateCurrentLtvWad(state, walletId, spokeId),
      healthFactorWad: calculateHealthFactorWad(state, walletId, spokeId),
    },
  }
}

function spokeForAction(state: BorrowSystemState, action: BorrowAction): BorrowSpokeId | undefined {
  if (action.type === "borrow" || action.type === "supplyCollateral") {
    return state.markets[action.marketId]?.spokeId
  }
  if (action.type === "repay") {
    return state.accounts[action.walletId]?.debtPositions.find((position) => position.id === action.debtPositionId)
      ?.spokeId
  }
  if (action.type === "removeCollateral" || action.type === "liquidate") {
    const marketId = state.accounts[action.walletId]?.collateralPositions.find(
      (position) => position.id === action.positionId,
    )?.marketId
    return marketId ? state.markets[marketId]?.spokeId : undefined
  }
  return undefined
}

function labelRisk(healthFactorWad: bigint | null): SimulationRiskLabel {
  if (healthFactorWad == null) return "safe"
  if (healthFactorWad < 1_000000000000000000n) return "danger"
  if (healthFactorWad < 1_500000000000000000n) return "warning"
  return "safe"
}

function warningsFromSnapshot(actionType: BorrowAction["type"], after: SimulationSnapshot) {
  if (actionType === "claim") {
    return []
  }
  const warnings: string[] = []
  const healthFactor = after.metrics.healthFactorWad
  if (healthFactor != null && healthFactor < 1_500000000000000000n) {
    warnings.push(`${actionType} leaves the position close to liquidation`)
  }
  return warnings
}

function previewAction<TAction extends BorrowAction>(
  state: BorrowSystemState,
  action: TAction,
): BorrowSimulationResult {
  const spokeId = spokeForAction(state, action)
  const before = snapshot(state, action.walletId, spokeId)

  try {
    const nextState = applyBorrowAction(state, action)
    const after = snapshot(nextState, action.walletId, spokeId)
    return {
      actionType: action.type,
      allowed: true,
      warnings: warningsFromSnapshot(action.type, after),
      validationErrors: [],
      riskLabel: labelRisk(after.metrics.healthFactorWad),
      before,
      after,
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    return {
      actionType: action.type,
      allowed: false,
      warnings: [],
      validationErrors: [message],
      riskLabel: labelRisk(before.metrics.healthFactorWad),
      before,
      after: before,
    }
  }
}

export function simulateDeposit(state: BorrowSystemState, action: Extract<BorrowAction, { type: "supplyCollateral" }>) {
  return previewAction(state, action)
}

export function simulateBorrow(state: BorrowSystemState, action: Extract<BorrowAction, { type: "borrow" }>) {
  return previewAction(state, action)
}

export function simulateRepay(state: BorrowSystemState, action: Extract<BorrowAction, { type: "repay" }>) {
  return previewAction(state, action)
}

export function simulateWithdraw(
  state: BorrowSystemState,
  action: Extract<BorrowAction, { type: "removeCollateral" }>,
) {
  return previewAction(state, action)
}

export function simulateLiquidation(state: BorrowSystemState, action: Extract<BorrowAction, { type: "liquidate" }>) {
  return previewAction(state, action)
}

export function simulateClaim(state: BorrowSystemState, action: Extract<BorrowAction, { type: "claim" }>) {
  return previewAction(state, action)
}
