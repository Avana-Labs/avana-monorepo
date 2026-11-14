import type { InterestRateModelParams } from "@/app/lib/borrow-detail/protocol-parameters"

export type InterestRateCurvePoint = { utilization: number; apr: number }

export type InterestRateCurve = {
  points: InterestRateCurvePoint[]
  currentUtilization: number
  optimalUtilization: number
  maxApr: number
  /** Anchored borrow APR at 0% utilization (the curve's y-intercept, clamped ≥ 0). */
  baseApr: number
  yTicks: number[]
}

/** Round up to a 1–2–5×10^n ceiling so axis labels stay readable. */
export function niceCeil(value: number): number {
  if (!Number.isFinite(value) || value <= 0) return 10
  const magnitude = 10 ** Math.floor(Math.log10(value))
  const normalized = value / magnitude
  const nice = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10
  return nice * magnitude
}

/** Evenly spaced Y ticks from 0 to a nice ceiling covering `maxApr`. */
export function buildPercentAxisTicks(maxApr: number, tickCount = 4): number[] {
  const top = niceCeil(maxApr)
  const steps = Math.max(2, tickCount) - 1
  const step = top / steps
  return Array.from({ length: steps + 1 }, (_, index) => Math.round(step * index * 100) / 100)
}

const clampUtil = (utilization: number) => Math.min(100, Math.max(0, utilization))

/**
 * Kinked borrow APR *shape* at a utilization, expressed RELATIVE to the base rate:
 * 0 at 0% util, rising to `slopeBelowOptimal` at the optimal kink, then steepening by
 * `slopeAboveOptimal` up to 100%. The absolute APR is `base + shape`.
 */
function shapeAprAboveBase(utilization: number, irm: InterestRateModelParams): number {
  const optimal = clampUtil(irm.optimalUtilizationPct)
  if (optimal <= 0) {
    return irm.slopeBelowOptimalPct + irm.slopeAboveOptimalPct * (utilization / 100)
  }
  if (utilization <= optimal) {
    return irm.slopeBelowOptimalPct * (utilization / optimal)
  }
  const span = 100 - optimal
  if (span <= 0) return irm.slopeBelowOptimalPct
  return irm.slopeBelowOptimalPct + irm.slopeAboveOptimalPct * ((utilization - optimal) / span)
}

/**
 * Borrow APR the kinked IRM charges at `utilization`.
 *
 * When an `anchor` (the current utilization + the rate actually paid) is supplied, the
 * curve's base rate is solved so the curve passes EXACTLY through that point —
 * `borrowAprAtUtilization(anchor.utilization, irm, anchor) === anchor.apr`. The kink
 * shape (optimal + both slopes) is preserved; only the vertical position is anchored to
 * the real rate, so the "Current" marker always lands on the displayed/paid APR rather
 * than on a value reconstructed from the (slug-hashed, rate-independent) base param.
 */
export function borrowAprAtUtilization(
  utilization: number,
  irm: InterestRateModelParams,
  anchor?: { utilization: number; apr: number },
): number {
  const rel = shapeAprAboveBase(clampUtil(utilization), irm)
  const base = anchor ? anchor.apr - shapeAprAboveBase(clampUtil(anchor.utilization), irm) : irm.baseBorrowRatePct
  return Math.max(0, base + rel)
}

/** Kinked borrow APR curve anchored to the real rate paid at the current utilization. */
export function buildBorrowInterestRateCurve(
  currentUtilization: number,
  currentBorrowApr: number,
  irm: InterestRateModelParams,
): InterestRateCurve {
  const clampedCurrent = clampUtil(currentUtilization)
  const anchor = { utilization: clampedCurrent, apr: Math.max(0, currentBorrowApr) }
  const optimalUtilization = clampUtil(irm.optimalUtilizationPct)

  const points: InterestRateCurvePoint[] = []
  for (let util = 0; util <= 100; util += 1) {
    points.push({ utilization: util, apr: borrowAprAtUtilization(util, irm, anchor) })
  }

  const baseApr = borrowAprAtUtilization(0, irm, anchor)
  const rawMax = Math.max(...points.map((point) => point.apr), anchor.apr + 2, 1)
  const maxApr = niceCeil(rawMax)

  return {
    points,
    currentUtilization: clampedCurrent,
    optimalUtilization,
    maxApr,
    baseApr,
    yTicks: buildPercentAxisTicks(maxApr),
  }
}

/**
 * Extra borrow (positive) or repay (negative) USD needed so utilization equals
 * `targetUtilizationPct`, holding total supplied liquidity fixed:
 *   ΔB = S · (U_target / 100) − B
 */
export function borrowDeltaUsdToUtilization(
  targetUtilizationPct: number,
  borrowedUsd: number,
  suppliedUsd: number,
): number {
  if (!Number.isFinite(suppliedUsd) || suppliedUsd <= 0) return 0
  const borrowed = Number.isFinite(borrowedUsd) ? Math.max(0, borrowedUsd) : 0
  const targetBorrowed = suppliedUsd * (clampUtil(targetUtilizationPct) / 100)
  return targetBorrowed - borrowed
}

export type InterestRateModelProbe = {
  utilizationPct: number
  borrowAprPct: number
  borrowDeltaUsd: number
}

/**
 * Single-source probe for the IRM chart tooltip: APR on the anchored curve plus
 * the borrow delta to reach that utilization at fixed supply.
 */
export function probeInterestRateModel(args: {
  utilizationPct: number
  irm: InterestRateModelParams
  anchor: { utilization: number; apr: number }
  borrowedUsd: number
  suppliedUsd: number
}): InterestRateModelProbe {
  const utilizationPct = clampUtil(args.utilizationPct)
  return {
    utilizationPct,
    borrowAprPct: borrowAprAtUtilization(utilizationPct, args.irm, args.anchor),
    borrowDeltaUsd: borrowDeltaUsdToUtilization(utilizationPct, args.borrowedUsd, args.suppliedUsd),
  }
}

/**
 * Normalize liquidity so current utilization is internally consistent:
 * when only one of borrowed/supplied is known, derive the other from util.
 */
export function resolveMarketLiquidityUsd(args: {
  utilizationPct: number
  borrowedUsd?: number
  suppliedUsd?: number
}): { borrowedUsd: number; suppliedUsd: number } {
  const util = clampUtil(args.utilizationPct) / 100
  let borrowedUsd = Number.isFinite(args.borrowedUsd) ? Math.max(0, args.borrowedUsd!) : 0
  let suppliedUsd = Number.isFinite(args.suppliedUsd) ? Math.max(0, args.suppliedUsd!) : 0

  if (suppliedUsd <= 0 && borrowedUsd > 0 && util > 0) {
    suppliedUsd = borrowedUsd / util
  } else if (borrowedUsd <= 0 && suppliedUsd > 0) {
    borrowedUsd = suppliedUsd * util
  } else if (suppliedUsd <= 0) {
    suppliedUsd = 100_000_000
    borrowedUsd = suppliedUsd * util
  }

  return { borrowedUsd, suppliedUsd }
}
