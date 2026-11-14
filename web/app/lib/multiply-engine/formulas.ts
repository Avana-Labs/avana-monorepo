export function calculateTheoreticalMaxMultiplier(maxLtv: number): number {
  if (maxLtv >= 1) return Number.POSITIVE_INFINITY
  return 1 / (1 - maxLtv)
}

export function calculateSafeMaxMultiplier(params: {
  publicMaxMultiplier: number
  theoreticalMaxMultiplier: number
  minHealthFactor: number
  liquidationThreshold: number
}): number {
  // When minHealthFactor <= liquidationThreshold the HF-based bound is negative or
  // infinite; treat it as non-binding so the safe max never goes negative.
  const denominator = params.minHealthFactor - params.liquidationThreshold
  const hfBased = denominator > 0 ? params.minHealthFactor / denominator : Number.POSITIVE_INFINITY
  return Math.min(params.publicMaxMultiplier, params.theoreticalMaxMultiplier, hfBased)
}

export function calculateMultiplyLtv(debtValueUsd: number, collateralValueUsd: number): number {
  if (collateralValueUsd <= 0) return 0
  return debtValueUsd / collateralValueUsd
}

export function calculateMultiplyHealthFactor(
  collateralValueUsd: number,
  debtValueUsd: number,
  liquidationThreshold: number,
): number | "infinity" {
  if (debtValueUsd <= 0) return "infinity"
  return (collateralValueUsd * liquidationThreshold) / debtValueUsd
}

export function calculateLiquidationPrice(params: {
  debtValueUsd: number
  collateralAmount: number
  liquidationThreshold: number
}): number | null {
  if (params.debtValueUsd <= 0 || params.collateralAmount <= 0 || params.liquidationThreshold <= 0) {
    return null
  }
  return params.debtValueUsd / (params.collateralAmount * params.liquidationThreshold)
}

export function calculateNetApy(params: {
  supplyApy: number
  borrowApy: number
  finalCollateralValueUsd: number
  debtValueUsd: number
  initialCollateralValueUsd: number
}): number {
  if (params.initialCollateralValueUsd <= 0) return 0
  return (
    (params.supplyApy * params.finalCollateralValueUsd - params.borrowApy * params.debtValueUsd) /
    params.initialCollateralValueUsd
  )
}

export function calculateMaxLeverageApy(params: {
  supplyApy: number
  borrowApy: number
  safeMaxMultiplier: number
}): number {
  return params.supplyApy * params.safeMaxMultiplier - params.borrowApy * (params.safeMaxMultiplier - 1)
}

export function calculatePriceImpact(params: {
  baseImpact: number
  multiplier: number
  availableLiquidityUsd: number
  collateralValueUsd: number
}): number {
  const multiplierImpact = Math.max(0, params.multiplier - 1) * 0.0005
  // Clamp the whole liquidity term, not just the ratio, so a position that is a large
  // fraction of available liquidity reaches ~1% impact instead of capping at 0.002%.
  const liquidityImpact =
    params.availableLiquidityUsd > 0
      ? Math.min(0.01, (params.collateralValueUsd / params.availableLiquidityUsd) * 0.002)
      : 0.002
  return params.baseImpact + multiplierImpact + liquidityImpact
}

export function calculatePriceDropToLiquidationPct(
  liquidationPrice: number | null,
  collateralPriceUsd: number,
): number | null {
  if (liquidationPrice === null || collateralPriceUsd <= 0) return null
  return 1 - liquidationPrice / collateralPriceUsd
}

export function calculateLoopSteps(maxLtv: number, targetMultiplier: number): number {
  if (targetMultiplier <= 1 || maxLtv >= 1) return 0
  const stepFactor = 1 / (1 - maxLtv)
  if (stepFactor <= 1) return 1
  return Math.max(1, Math.ceil(Math.log(targetMultiplier) / Math.log(stepFactor)))
}

type CollateralLoopResult = {
  collateralUsd: number
  debtUsd: number
  loops: number
  achievedMultiplier: number
}

/** Iterative supply → borrow → swap-to-collateral loop (Aave-style multiply). */
export function simulateCollateralLoop(params: {
  initialCollateralUsd: number
  targetMultiplier: number
  maxLtv: number
  swapEfficiency: number
  maxLoops?: number
}): CollateralLoopResult {
  const maxLoops = params.maxLoops ?? 24
  const equity = params.initialCollateralUsd
  let collateral = params.initialCollateralUsd
  let debt = 0
  let loops = 0

  if (equity <= 0 || params.targetMultiplier <= 1) {
    return { collateralUsd: collateral, debtUsd: debt, loops, achievedMultiplier: 1 }
  }

  const epsilon = 0.02

  while (loops < maxLoops) {
    const equityNow = collateral - debt
    if (equityNow <= epsilon) break

    const currentMultiplier = collateral / equityNow
    if (currentMultiplier >= params.targetMultiplier - epsilon) break

    const borrowPower = collateral * params.maxLtv - debt
    if (borrowPower <= epsilon) break

    const target = params.targetMultiplier
    const swapEfficiency = params.swapEfficiency
    const denominator = swapEfficiency - target * (swapEfficiency - 1)
    const idealBorrowUsd = denominator > epsilon ? (target * equityNow - collateral) / denominator : borrowPower
    const borrowUsd = Math.min(borrowPower, Math.max(0, idealBorrowUsd))

    if (borrowUsd <= epsilon) break

    debt += borrowUsd
    collateral += borrowUsd * swapEfficiency
    loops += 1

    if (borrowUsd < borrowPower - epsilon) break
  }

  const equityFinal = collateral - debt
  const achievedMultiplier = equityFinal > 0 ? collateral / equityFinal : 1

  return { collateralUsd: collateral, debtUsd: debt, loops, achievedMultiplier }
}

export function simulateDeleverageToTarget(params: {
  collateralUsd: number
  debtUsd: number
  targetMultiplier: number
  swapEfficiency: number
  repayAmountUsd?: number
}): { collateralUsd: number; debtUsd: number; debtRepaidUsd: number; collateralUnwoundUsd: number } {
  const { collateralUsd: startCollateral, debtUsd: startDebt, targetMultiplier, swapEfficiency } = params
  const collateral = startCollateral
  const debt = startDebt

  if (params.repayAmountUsd != null && params.repayAmountUsd > 0) {
    const repayUsd = Math.min(params.repayAmountUsd, debt)
    const collateralSold = repayUsd / Math.max(swapEfficiency, 0.0001)
    return {
      collateralUsd: Math.max(0, collateral - collateralSold),
      debtUsd: Math.max(0, debt - repayUsd),
      debtRepaidUsd: repayUsd,
      collateralUnwoundUsd: collateralSold,
    }
  }

  const equity = collateral - debt
  if (targetMultiplier <= 1) {
    // A full deleverage must sell collateral to repay. Zeroing debt without reducing collateral
    // inflates equity, which the Convex ledger reads as a wallet-funded deposit and rejects.
    const repayUsd = Math.min(debt, collateral * Math.max(swapEfficiency, 0.0001))
    const collateralUnwoundUsd = repayUsd / Math.max(swapEfficiency, 0.0001)
    return {
      collateralUsd: Math.max(0, collateral - collateralUnwoundUsd),
      debtUsd: Math.max(0, debt - repayUsd),
      debtRepaidUsd: repayUsd,
      collateralUnwoundUsd,
    }
  }

  if (equity <= 0) {
    return {
      collateralUsd: collateral,
      debtUsd: debt,
      debtRepaidUsd: 0,
      collateralUnwoundUsd: 0,
    }
  }

  const targetCollateral = equity * targetMultiplier
  const targetDebt = equity * Math.max(0, targetMultiplier - 1)
  const collateralUnwoundUsd = Math.max(0, collateral - targetCollateral)
  const debtRepaidUsd = Math.max(0, debt - targetDebt)

  return {
    collateralUsd: targetCollateral,
    debtUsd: targetDebt,
    debtRepaidUsd,
    collateralUnwoundUsd,
  }
}
