// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
/** Aave V4: a market's liquidation threshold equals its collateral factor (REQ-LENS-045). */
const liquidationThresholdPctFromMaxLtvPct = (maxLtvPct: number) => maxLtvPct

/**
 * Single source of every financial number an Ask AI mode run displays. Pure — no Convex,
 * React or network. Callers build ONE immutable {@link PositionContext} per run and read all
 * widget numbers from the `compute*` functions, so one answer can never mix two timestamps
 * or two position states.
 */

const DAYS_PER_YEAR = 365

export type RiskLevel = "low" | "elevated" | "critical"

/** A single leg of a (possibly LP) collateral position. Weights across a position sum to ~1. */
export type PositionConstituent = {
  symbol: string
  weight: number
  /** USD value of this leg, when the split is priced. */
  valueUsd?: number
  /** Trailing-7d fee APR for this leg (percent), when priced. */
  feeApr7dPct?: number
  /** Concentrated-LP in-range flag, when applicable. */
  inRange?: boolean
}

/** Raw, already-decoded inputs for one position. `buildPositionContext` turns this into an immutable snapshot. */
export type PositionSnapshotInput = {
  positionId: string
  product: "borrow" | "lend"
  collateralValueUsd: number
  debtValueUsd: number
  maxLtvPct: number
  /** Falls back to a maxLtv-derived threshold when omitted. */
  liquidationThresholdPct?: number
  /** Annual borrow rate on the debt (percent), when known. */
  borrowApyPct?: number
  /** Whole-position trailing-7d fee APR (percent), when known. */
  lpFeeApr7dPct?: number
  constituents?: PositionConstituent[]
  lastUpdatedAt: number
}

/** Immutable per-run snapshot. Every `compute*` reads from this, guaranteeing one shared state + timestamp. */
export type PositionContext = Readonly<{
  snapshotId: string
  asOf: number
  positionId: string
  product: PositionSnapshotInput["product"]
  collateralValueUsd: number
  debtValueUsd: number
  maxLtvPct: number
  liquidationThresholdPct: number
  borrowApyPct: number | null
  lpFeeApr7dPct: number | null
  constituents: readonly PositionConstituent[]
  currentLtv: number
  /** null = no debt (health factor is effectively infinite). */
  healthFactor: number | null
  lastUpdatedAt: number
}>

const finiteOrNull = (value: number): number | null => (Number.isFinite(value) ? value : null)

export function riskLevelFromHealthFactor(healthFactor: number | null): RiskLevel {
  if (healthFactor === null) return "low"
  if (healthFactor <= 1) return "critical"
  if (healthFactor < 1.5) return "elevated"
  return "low"
}

// A tiny, dependency-free FNV-1a hash so a snapshot's identity is deterministic across
// processes without pulling in a crypto/hashing dependency. Collisions are irrelevant
// here — the id only has to be stable and unique-enough within a wallet's runs.
function fnv1a(input: string): string {
  let hash = 0x811c9dc5
  for (let index = 0; index < input.length; index += 1) {
    hash ^= input.charCodeAt(index)
    hash = Math.imul(hash, 0x01000193)
  }
  return (hash >>> 0).toString(16).padStart(8, "0")
}

/** Deterministic snapshot id for a given input + timestamp. Same inputs → same id. */
export function snapshotIdFor(input: PositionSnapshotInput, asOf: number): string {
  const canonicalConstituents = (input.constituents ?? [])
    .map((c) => `${c.symbol.toUpperCase()}:${c.weight}:${c.valueUsd ?? ""}:${c.feeApr7dPct ?? ""}:${c.inRange ?? ""}`)
    .sort()
    .join("|")
  const canonical = [
    input.positionId,
    input.product,
    input.collateralValueUsd,
    input.debtValueUsd,
    input.maxLtvPct,
    input.liquidationThresholdPct ?? "",
    input.borrowApyPct ?? "",
    input.lpFeeApr7dPct ?? "",
    input.lastUpdatedAt,
    asOf,
    canonicalConstituents,
  ].join("~")
  return `snap_${fnv1a(canonical)}`
}

/**
 * Build the immutable snapshot for a run. The returned object (and its constituents array)
 * is frozen, so a widget cannot mutate shared state mid-answer.
 */
export function buildPositionContext(input: PositionSnapshotInput, asOf: number): PositionContext {
  const liquidationThresholdPct = input.liquidationThresholdPct ?? liquidationThresholdPctFromMaxLtvPct(input.maxLtvPct)
  const currentLtv = input.collateralValueUsd > 0 ? input.debtValueUsd / input.collateralValueUsd : 0
  const healthFactor =
    input.debtValueUsd > 0
      ? finiteOrNull((input.collateralValueUsd * (liquidationThresholdPct / 100)) / input.debtValueUsd)
      : null

  const constituents = Object.freeze((input.constituents ?? []).map((c) => Object.freeze({ ...c })))

  return Object.freeze({
    snapshotId: snapshotIdFor(input, asOf),
    asOf,
    positionId: input.positionId,
    product: input.product,
    collateralValueUsd: input.collateralValueUsd,
    debtValueUsd: input.debtValueUsd,
    maxLtvPct: input.maxLtvPct,
    liquidationThresholdPct,
    borrowApyPct: input.borrowApyPct ?? null,
    lpFeeApr7dPct: input.lpFeeApr7dPct ?? null,
    constituents,
    currentLtv,
    healthFactor,
    lastUpdatedAt: input.lastUpdatedAt,
  })
}

// ---------------------------------------------------------------------------
// Deterministic engine contract. Every displayed financial number comes from
// one of these functions, computed off a single PositionContext.
// ---------------------------------------------------------------------------

export type BorrowCapacityTarget = { healthFactor: number; borrowableUsd: number }
export type BorrowCapacity = {
  collateralValueUsd: number
  maxLtvPct: number
  liquidationThresholdPct: number
  maxDebtUsd: number
  currentDebtUsd: number
  availableUsd: number
  atHfTargets: BorrowCapacityTarget[]
}

/** Borrow room at the max-LTV limit and at configurable health-factor targets. */
export function computeBorrowCapacity(
  ctx: PositionContext,
  options: { healthFactorTargets?: number[] } = {},
): BorrowCapacity {
  const targets = options.healthFactorTargets ?? [1.5, 2]
  const maxDebtUsd = ctx.collateralValueUsd * (ctx.maxLtvPct / 100)
  const liquidationValue = ctx.collateralValueUsd * (ctx.liquidationThresholdPct / 100)
  return {
    collateralValueUsd: ctx.collateralValueUsd,
    maxLtvPct: ctx.maxLtvPct,
    liquidationThresholdPct: ctx.liquidationThresholdPct,
    maxDebtUsd,
    currentDebtUsd: ctx.debtValueUsd,
    availableUsd: Math.max(0, maxDebtUsd - ctx.debtValueUsd),
    atHfTargets: targets.map((healthFactor) => ({
      healthFactor,
      // Debt that keeps HF at the target: collateral * LT / target.
      borrowableUsd: Math.max(0, liquidationValue / healthFactor - ctx.debtValueUsd),
    })),
  }
}

type LiquidationBuffer = {
  healthFactor: number | null
  currentLtv: number
  liquidationThresholdPct: number
  /** Max % the collateral value can fall before HF reaches 1. No debt → 100 (cannot be liquidated). */
  bufferPct: number
  riskLevel: RiskLevel
}

export function computeLiquidationBuffer(ctx: PositionContext): LiquidationBuffer {
  const bufferPct = ctx.healthFactor === null ? 100 : Math.max(0, (1 - 1 / ctx.healthFactor) * 100)
  return {
    healthFactor: ctx.healthFactor,
    currentLtv: ctx.currentLtv,
    liquidationThresholdPct: ctx.liquidationThresholdPct,
    bufferPct,
    riskLevel: riskLevelFromHealthFactor(ctx.healthFactor),
  }
}

/** Debt to repay to lift the health factor to `targetHealthFactor`. 0 when already at or above it. */
export function repayToReachHealthFactor(ctx: PositionContext, targetHealthFactor: number): number {
  if (ctx.debtValueUsd <= 0 || targetHealthFactor <= 0) return 0
  const targetDebtUsd = (ctx.collateralValueUsd * (ctx.liquidationThresholdPct / 100)) / targetHealthFactor
  return Math.max(0, ctx.debtValueUsd - targetDebtUsd)
}

/** Collateral to add to lift the health factor to `targetHealthFactor`. 0 when already at or above it. */
export function addCollateralToReachHealthFactor(ctx: PositionContext, targetHealthFactor: number): number {
  if (ctx.debtValueUsd <= 0 || targetHealthFactor <= 0) return 0
  const targetCollateralUsd = (targetHealthFactor * ctx.debtValueUsd) / (ctx.liquidationThresholdPct / 100)
  return Math.max(0, targetCollateralUsd - ctx.collateralValueUsd)
}

type InterestPerDay = {
  debtUsd: number
  borrowApyPct: number | null
  /** null when there is debt but the rate is unknown; 0 when there is no debt. */
  interestPerDayUsd: number | null
}

export function computeInterestPerDay(ctx: PositionContext): InterestPerDay {
  const interestPerDayUsd =
    ctx.debtValueUsd <= 0
      ? 0
      : ctx.borrowApyPct === null
        ? null
        : (ctx.debtValueUsd * (ctx.borrowApyPct / 100)) / DAYS_PER_YEAR
  return { debtUsd: ctx.debtValueUsd, borrowApyPct: ctx.borrowApyPct, interestPerDayUsd }
}

type FeePerDay = {
  lpValueUsd: number
  feeApr7dPct: number | null
  /** null when no fee data is available for the position. */
  feePerDayUsd: number | null
}

/** Fee accrual per day. Uses the whole-position fee APR, falling back to a weighted blend of priced legs. */
export function computeFeePerDay(ctx: PositionContext): FeePerDay {
  const feeApr7dPct = ctx.lpFeeApr7dPct ?? weightedFeeApr(ctx.constituents)
  const feePerDayUsd = feeApr7dPct === null ? null : (ctx.collateralValueUsd * (feeApr7dPct / 100)) / DAYS_PER_YEAR
  return { lpValueUsd: ctx.collateralValueUsd, feeApr7dPct, feePerDayUsd }
}

function weightedFeeApr(constituents: readonly PositionConstituent[]): number | null {
  const priced = constituents.filter((c) => typeof c.feeApr7dPct === "number")
  if (priced.length === 0) return null
  const totalWeight = priced.reduce((sum, c) => sum + c.weight, 0)
  if (totalWeight <= 0) return null
  return priced.reduce((sum, c) => sum + c.weight * (c.feeApr7dPct ?? 0), 0) / totalWeight
}

export type NetCarry = {
  feePerDayUsd: number | null
  interestPerDayUsd: number | null
  netCarryPerDayUsd: number | null
  projected7dUsd: number | null
  projected30dUsd: number | null
}

/**
 * No-leverage net carry: fee income minus borrow interest. Returns nulls (not a fake $0)
 * whenever an input the number depends on is unknown, so the UI can honestly show "—".
 */
export function computeNetCarry(ctx: PositionContext): NetCarry {
  const { feePerDayUsd } = computeFeePerDay(ctx)
  const { interestPerDayUsd } = computeInterestPerDay(ctx)
  const netCarryPerDayUsd =
    feePerDayUsd === null || interestPerDayUsd === null ? null : feePerDayUsd - interestPerDayUsd
  return {
    feePerDayUsd,
    interestPerDayUsd,
    netCarryPerDayUsd,
    projected7dUsd: netCarryPerDayUsd === null ? null : netCarryPerDayUsd * 7,
    projected30dUsd: netCarryPerDayUsd === null ? null : netCarryPerDayUsd * 30,
  }
}

export type StressOutcome = {
  priceShockPct: number
  shockedCollateralValueUsd: number
  ltv: number
  healthFactor: number | null
  liquidated: boolean
}

/** Apply a uniform collateral price shock (e.g. -10, -20, -30) and report the resulting risk. */
export function simulateStress(ctx: PositionContext, priceShockPct: number): StressOutcome {
  const shockedCollateralValueUsd = Math.max(0, ctx.collateralValueUsd * (1 + priceShockPct / 100))
  const ltv =
    ctx.debtValueUsd <= 0
      ? 0
      : shockedCollateralValueUsd > 0
        ? ctx.debtValueUsd / shockedCollateralValueUsd
        : Number.POSITIVE_INFINITY
  const healthFactor =
    ctx.debtValueUsd > 0
      ? finiteOrNull((shockedCollateralValueUsd * (ctx.liquidationThresholdPct / 100)) / ctx.debtValueUsd)
      : null
  return {
    priceShockPct,
    shockedCollateralValueUsd,
    ltv,
    healthFactor,
    liquidated: healthFactor !== null && healthFactor <= 1,
  }
}

export type LiquidationBoundaryPoint = { priceShockPct: number; healthFactor: number | null }
export type LiquidationBoundary = {
  points: LiquidationBoundaryPoint[]
  /** Exact collateral price shock (percent, negative) at which HF hits 1. null when there is no debt. */
  liquidationPriceShockPct: number | null
}

/** Price-vs-health-factor curve for the boundary chart, plus the exact liquidation shock. */
export function computeLiquidationBoundaryCurve(
  ctx: PositionContext,
  options: { stepPct?: number; minShockPct?: number } = {},
): LiquidationBoundary {
  const stepPct = Math.abs(options.stepPct ?? 5)
  const minShockPct = options.minShockPct ?? -50
  const points: LiquidationBoundaryPoint[] = []
  for (let shock = 0; shock >= minShockPct - 1e-9; shock -= stepPct) {
    points.push({ priceShockPct: shock, healthFactor: simulateStress(ctx, shock).healthFactor })
  }
  // HF scales linearly with collateral: HF(shock) = HF0 * (1 + shock/100). HF = 1 at
  // shock = (1/HF0 - 1) * 100.
  const liquidationPriceShockPct =
    ctx.healthFactor === null || ctx.healthFactor <= 0 ? null : (1 / ctx.healthFactor - 1) * 100
  return { points, liquidationPriceShockPct }
}

export type ComparableLPInput = {
  id: string
  label: string
  feeApr7dPct: number
  borrowApyPct?: number
  lpValueUsd?: number
}
export type ComparableLP = ComparableLPInput & {
  netApyPct: number
  netCarryPerDayUsd: number | null
}

/** Rank candidate LPs by net APY (fee APR minus borrow cost), best first. Pure over the given candidates. */
export function rankComparableLPs(ctx: PositionContext, candidates: ComparableLPInput[]): ComparableLP[] {
  return candidates
    .map((candidate) => {
      const netApyPct = candidate.feeApr7dPct - (candidate.borrowApyPct ?? 0)
      const lpValueUsd = candidate.lpValueUsd ?? ctx.collateralValueUsd
      return {
        ...candidate,
        netApyPct,
        netCarryPerDayUsd: (lpValueUsd * (netApyPct / 100)) / DAYS_PER_YEAR,
      }
    })
    .sort((a, b) => b.netApyPct - a.netApyPct)
}
