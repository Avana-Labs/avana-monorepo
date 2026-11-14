// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import {
  computeBorrowCapacity,
  computeFeePerDay,
  computeInterestPerDay,
  computeLiquidationBoundaryCurve,
  computeLiquidationBuffer,
  computeNetCarry,
  rankComparableLPs,
  simulateStress,
  type BorrowCapacity,
  type ComparableLP,
  type ComparableLPInput,
  type LiquidationBoundary,
  type NetCarry,
  type PositionConstituent,
  type PositionContext,
  type RiskLevel,
  type StressOutcome,
} from "./positionContext"

/**
 * Typed Ask AI widgets. Each is only constructible by a `build*Widget` taking a
 * {@link PositionContext}, so the type system alone rules out rendering a financial number
 * that didn't come from the engine's single run snapshot. Widgets carry raw numbers;
 * formatting stays in the UI.
 */

/** Length of the trailing fee-APR window the carry/fee widgets assume. */
export const FEE_WINDOW_DAYS = 7

export type CollateralLeg = PositionConstituent

export type AskAiWidget =
  | { type: "risk_summary"; healthFactor: number | null; bufferPct: number; currentLtv: number; riskLevel: RiskLevel }
  | { type: "borrow_capacity"; capacity: BorrowCapacity }
  | { type: "collateral_breakdown"; totalValueUsd: number; legs: CollateralLeg[] }
  | { type: "liquidation_boundary"; boundary: LiquidationBoundary; healthFactor: number | null }
  | { type: "carry_summary"; carry: NetCarry }
  | { type: "fee_vs_interest"; feePerDayUsd: number | null; interestPerDayUsd: number | null }
  | { type: "stress_tiles"; presets: StressOutcome[] }
  | { type: "comparable_lp"; rows: ComparableLP[] }
  | {
      type: "assumptions"
      snapshotId: string
      asOf: number
      maxLtvPct: number
      liquidationThresholdPct: number
      feeWindowDays: number
      provenance: string
    }

type AskAiWidgetType = AskAiWidget["type"]

/** Every known widget discriminant. The `satisfies` keeps it in sync with the union. */
export const ASK_AI_WIDGET_TYPES = [
  "risk_summary",
  "borrow_capacity",
  "collateral_breakdown",
  "liquidation_boundary",
  "carry_summary",
  "fee_vs_interest",
  "stress_tiles",
  "comparable_lp",
  "assumptions",
] as const satisfies readonly AskAiWidgetType[]

export type AskAiActionKind = "repay" | "add_collateral" | "borrow" | "reduce_leverage" | "review"
export type AskAiAction = {
  id: string
  kind: AskAiActionKind
  label: string
  amountUsd?: number
  rationale: string
  /** Health factor the position would reach if the action were taken, when computable. */
  resultingHealthFactor?: number
}

export function buildRiskSummaryWidget(ctx: PositionContext): Extract<AskAiWidget, { type: "risk_summary" }> {
  const buffer = computeLiquidationBuffer(ctx)
  return {
    type: "risk_summary",
    healthFactor: buffer.healthFactor,
    bufferPct: buffer.bufferPct,
    currentLtv: buffer.currentLtv,
    riskLevel: buffer.riskLevel,
  }
}

export function buildBorrowCapacityWidget(
  ctx: PositionContext,
  options: { healthFactorTargets?: number[] } = {},
): Extract<AskAiWidget, { type: "borrow_capacity" }> {
  return { type: "borrow_capacity", capacity: computeBorrowCapacity(ctx, options) }
}

export function buildCollateralBreakdownWidget(
  ctx: PositionContext,
): Extract<AskAiWidget, { type: "collateral_breakdown" }> {
  return {
    type: "collateral_breakdown",
    totalValueUsd: ctx.collateralValueUsd,
    legs: ctx.constituents.map((leg) => ({ ...leg })),
  }
}

export function buildLiquidationBoundaryWidget(
  ctx: PositionContext,
  options: { stepPct?: number; minShockPct?: number } = {},
): Extract<AskAiWidget, { type: "liquidation_boundary" }> {
  return {
    type: "liquidation_boundary",
    boundary: computeLiquidationBoundaryCurve(ctx, options),
    healthFactor: ctx.healthFactor,
  }
}

export function buildCarrySummaryWidget(ctx: PositionContext): Extract<AskAiWidget, { type: "carry_summary" }> {
  return { type: "carry_summary", carry: computeNetCarry(ctx) }
}

export function buildFeeVsInterestWidget(ctx: PositionContext): Extract<AskAiWidget, { type: "fee_vs_interest" }> {
  return {
    type: "fee_vs_interest",
    feePerDayUsd: computeFeePerDay(ctx).feePerDayUsd,
    interestPerDayUsd: computeInterestPerDay(ctx).interestPerDayUsd,
  }
}

/** Default stress presets shown as tiles: -10% / -20% / -30%. */
export const DEFAULT_STRESS_SHOCKS_PCT = [-10, -20, -30] as const

export function buildStressTilesWidget(
  ctx: PositionContext,
  shocksPct: readonly number[] = DEFAULT_STRESS_SHOCKS_PCT,
): Extract<AskAiWidget, { type: "stress_tiles" }> {
  return { type: "stress_tiles", presets: shocksPct.map((shock) => simulateStress(ctx, shock)) }
}

export function buildComparableLpWidget(
  ctx: PositionContext,
  candidates: ComparableLPInput[],
): Extract<AskAiWidget, { type: "comparable_lp" }> {
  return { type: "comparable_lp", rows: rankComparableLPs(ctx, candidates) }
}

export function buildAssumptionsWidget(
  ctx: PositionContext,
  options: { provenance: string },
): Extract<AskAiWidget, { type: "assumptions" }> {
  return {
    type: "assumptions",
    snapshotId: ctx.snapshotId,
    asOf: ctx.asOf,
    maxLtvPct: ctx.maxLtvPct,
    liquidationThresholdPct: ctx.liquidationThresholdPct,
    feeWindowDays: FEE_WINDOW_DAYS,
    provenance: options.provenance,
  }
}
