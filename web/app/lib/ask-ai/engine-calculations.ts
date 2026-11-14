import { calculateSimpleInterestAccrued, calculateTotalApy } from "@/app/lib/lend-system/model"
import { calculateMultiplyHealthFactor, calculateMultiplyLtv } from "@/app/lib/multiply-engine"
import { derivePersistedUmbrellaPositionStatus } from "@/app/lib/umbrella-system/portfolio-mapper"
import { liquidationThresholdPctFromMaxLtvPct } from "@/app/lib/borrow-system/liquidation-threshold"

const USD6 = 1_000_000
const WAD = 1_000_000_000_000_000_000

export function decodeBorrowRiskSnapshot(snapshot: {
  collateralValueUsd6: string
  borrowCapacityUsd6: string
  availableBorrowCapacityUsd6: string
  totalBorrowedUsd6: string
  currentLtvWad: string
  healthFactorWad: string | null
}) {
  return {
    collateralValueUsd: Number(snapshot.collateralValueUsd6) / USD6,
    borrowCapacityUsd: Number(snapshot.borrowCapacityUsd6) / USD6,
    availableBorrowCapacityUsd: Number(snapshot.availableBorrowCapacityUsd6) / USD6,
    totalBorrowedUsd: Number(snapshot.totalBorrowedUsd6) / USD6,
    currentLtv: Number(snapshot.currentLtvWad) / WAD,
    healthFactor: snapshot.healthFactorWad === null ? null : Number(snapshot.healthFactorWad) / WAD,
  }
}

/** A health factor as it is actually stored: a number, the literal string
 * "infinity" when there is no debt (multiply-engine/formulas.ts), or absent. */
type AskAIHealthFactor = number | "infinity" | null | undefined

/** One shared wording for "am I safe?", so every surface agrees. */
export function askAIRiskLevel(healthFactor: AskAIHealthFactor): "low" | "elevated" | "critical" | "none" {
  // No debt means nothing to liquidate, which is the safest state, not unknown.
  if (healthFactor === "infinity" || healthFactor === Number.POSITIVE_INFINITY) return "low"
  if (healthFactor === null || healthFactor === undefined || !Number.isFinite(healthFactor)) return "none"
  if (healthFactor <= 1) return "critical"
  if (healthFactor < 1.5) return "elevated"
  return "low"
}

/** How far above liquidation the position sits. HF 1.0 is the liquidation line.
 * Null when there is no debt or no health factor, since "infinite headroom" is
 * not a number the model should try to render. */
function askAIHealthFactorHeadroom(healthFactor: AskAIHealthFactor): number | null {
  return typeof healthFactor === "number" && Number.isFinite(healthFactor) ? healthFactor - 1 : null
}

/** Normalise a stored health factor for the model: a finite number or null,
 * never the bare string "infinity". `noDebt` distinguishes the two cases. */
export function askAIHealthFactorValue(healthFactor: AskAIHealthFactor) {
  const noDebt = healthFactor === "infinity" || healthFactor === Number.POSITIVE_INFINITY
  return {
    healthFactor: typeof healthFactor === "number" && Number.isFinite(healthFactor) ? healthFactor : null,
    noDebt,
    riskLevel: askAIRiskLevel(healthFactor),
    healthFactorHeadroom: askAIHealthFactorHeadroom(healthFactor),
  }
}

/**
 * Interest a borrow accrues over a window, mirroring calculateLendProjection so
 * "how much interest will I pay?" has a figure instead of model arithmetic.
 */
export function calculateBorrowProjection(params: { debtUsd: number; borrowAprPct: number; days: number }) {
  const days = Math.max(0, params.days)
  return {
    borrowAprPct: params.borrowAprPct,
    projectedInterestUsd: calculateSimpleInterestAccrued(params.debtUsd, params.borrowAprPct / 100, days / 365),
    days,
  }
}

export function calculateLendProjection(params: {
  principalUsd: number
  supplyApyPct: number
  rewardsApyPct?: number
  days: number
}) {
  const totalApy = calculateTotalApy(params.supplyApyPct / 100, (params.rewardsApyPct ?? 0) / 100)
  const elapsedYears = Math.max(0, params.days) / 365
  return {
    totalApyPct: totalApy * 100,
    projectedYieldUsd: calculateSimpleInterestAccrued(params.principalUsd, totalApy, elapsedYears),
    days: Math.max(0, params.days),
  }
}

export function calculateMultiplyStress(params: {
  collateralValueUsd: number
  debtValueUsd: number
  liquidationThresholdPct: number
  collateralPriceShockPct: number
}) {
  const shockedCollateralValueUsd = Math.max(0, params.collateralValueUsd * (1 + params.collateralPriceShockPct / 100))
  const liquidationThreshold = params.liquidationThresholdPct / 100
  return {
    collateralPriceShockPct: params.collateralPriceShockPct,
    shockedCollateralValueUsd,
    ltv: calculateMultiplyLtv(params.debtValueUsd, shockedCollateralValueUsd),
    healthFactor: calculateMultiplyHealthFactor(shockedCollateralValueUsd, params.debtValueUsd, liquidationThreshold),
    collateralLossUsd: Math.max(0, params.collateralValueUsd - shockedCollateralValueUsd),
    riskLevel: askAIRiskLevel(
      calculateMultiplyHealthFactor(shockedCollateralValueUsd, params.debtValueUsd, liquidationThreshold),
    ),
  }
}

export function calculateAskAICollateralStress(params: {
  collateralValueUsd: number
  debtValueUsd: number
  liquidationThresholdPct: number
  constituents: Array<{ symbol: string; weight: number }>
  assetPriceChanges: Record<string, number>
}) {
  const normalizedChanges = new Map(
    Object.entries(params.assetPriceChanges).map(([symbol, change]) => [symbol.toUpperCase(), change]),
  )
  const modeled = params.constituents.filter((constituent) => normalizedChanges.has(constituent.symbol.toUpperCase()))
  if (modeled.length === 0) throw new Error("The scenario does not match this position's collateral assets")
  const weightedChange = params.constituents.reduce(
    (total, constituent) => total + constituent.weight * (normalizedChanges.get(constituent.symbol.toUpperCase()) ?? 0),
    0,
  )
  const shockedCollateralValueUsd = Math.max(0, params.collateralValueUsd * (1 + weightedChange))
  const currentLtv = params.collateralValueUsd > 0 ? params.debtValueUsd / params.collateralValueUsd : 0
  const projectedLtv =
    shockedCollateralValueUsd > 0 ? params.debtValueUsd / shockedCollateralValueUsd : Number.POSITIVE_INFINITY
  const currentHealthFactor =
    params.debtValueUsd > 0
      ? (params.collateralValueUsd * (params.liquidationThresholdPct / 100)) / params.debtValueUsd
      : null
  const projectedHealthFactor =
    params.debtValueUsd > 0
      ? (shockedCollateralValueUsd * (params.liquidationThresholdPct / 100)) / params.debtValueUsd
      : null
  return {
    assetPriceChanges: Object.fromEntries(normalizedChanges),
    weightedCollateralChange: weightedChange,
    current: {
      collateralValueUsd: params.collateralValueUsd,
      debtValueUsd: params.debtValueUsd,
      ltv: currentLtv,
      healthFactor: currentHealthFactor,
    },
    projected: {
      collateralValueUsd: shockedCollateralValueUsd,
      debtValueUsd: params.debtValueUsd,
      ltv: projectedLtv,
      healthFactor: projectedHealthFactor,
    },
    liquidationThresholdPct: params.liquidationThresholdPct,
    liquidatable: projectedHealthFactor !== null && projectedHealthFactor <= 1,
    // "How much would I lose in a 30% drop?" — the dollar figure, so the model
    // never subtracts two collateral values itself.
    collateralLossUsd: Math.max(0, params.collateralValueUsd - shockedCollateralValueUsd),
    riskLevel: askAIRiskLevel(projectedHealthFactor),
    healthFactorHeadroom: askAIHealthFactorHeadroom(projectedHealthFactor),
  }
}

export function calculateAskAIBorrowSimulation(params: {
  collateralValueUsd: number
  debtValueUsd: number
  additionalBorrowAmountUsd: number
  maxLtvPct: number
  liquidationThresholdPct?: number
}) {
  const liquidationThresholdPct =
    params.liquidationThresholdPct ?? liquidationThresholdPctFromMaxLtvPct(params.maxLtvPct)
  const projectedDebtValueUsd = params.debtValueUsd + params.additionalBorrowAmountUsd
  const ratio = (debt: number) => (params.collateralValueUsd > 0 ? debt / params.collateralValueUsd : 0)
  const health = (debt: number) =>
    debt > 0 ? (params.collateralValueUsd * (liquidationThresholdPct / 100)) / debt : null
  const maxDebtUsd = params.collateralValueUsd * (params.maxLtvPct / 100)
  const projectedHealthFactor = health(projectedDebtValueUsd)
  return {
    current: {
      collateralValueUsd: params.collateralValueUsd,
      debtValueUsd: params.debtValueUsd,
      ltv: ratio(params.debtValueUsd),
      healthFactor: health(params.debtValueUsd),
    },
    projected: {
      collateralValueUsd: params.collateralValueUsd,
      debtValueUsd: projectedDebtValueUsd,
      ltv: ratio(projectedDebtValueUsd),
      healthFactor: projectedHealthFactor,
    },
    maxLtvPct: params.maxLtvPct,
    liquidationThresholdPct,
    remainingBorrowCapacityUsd: Math.max(0, maxDebtUsd - projectedDebtValueUsd),
    overMaxBorrowLtv: projectedDebtValueUsd > maxDebtUsd,
    liquidatable: projectedHealthFactor !== null && projectedHealthFactor <= 1,
    riskLevel: projectedHealthFactor === null ? ("low" as const) : askAIRiskLevel(projectedHealthFactor),
    healthFactorHeadroom: askAIHealthFactorHeadroom(projectedHealthFactor),
  }
}

export function deriveAskAIUmbrellaStatus(position: {
  status: "open" | "closed"
  suppliedUsd6?: string
  cooldownAmountUsd6?: string
  cooldownEndsAt?: number
  withdrawalWindowEndsAt?: number
  slashedAmountUsd6?: string
  now: number
}) {
  return derivePersistedUmbrellaPositionStatus(position)
}
