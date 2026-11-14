import {
  calculateLiquidationPrice,
  calculateMaxLeverageApy,
  calculateMultiplyHealthFactor,
  calculateMultiplyLtv,
  calculateNetApy,
  calculatePriceDropToLiquidationPct,
  calculatePriceImpact,
  calculateSafeMaxMultiplier,
  calculateTheoreticalMaxMultiplier,
  simulateCollateralLoop,
  simulateDeleverageToTarget,
} from "./formulas"
import type { DeleverageSimulation, MultiplyMarketRecord, MultiplyPosition, MultiplySimulation } from "./types"
import { validateDeleverageAction, validateMultiplyAction } from "./validation"

const DEFAULT_BASE_IMPACT = 0.001
const MAX_ALLOWED_PRICE_IMPACT = 0.05

/**
 * Re-price a stored multiply position against the CURRENT collateral price and
 * re-derive its dollar figures with the SAME engine math a live simulation uses
 * (`calculateMultiplyHealthFactor` / `calculateMultiplyLtv` / `calculateLiquidationPrice`).
 *
 * The stored primitives are `collateralAmount` (token quantity) and `debtValueUsd`;
 * everything else (`collateralValueUsd`, `healthFactor`, `ltv`, `liquidationPrice`) is
 * derived so a freshly-hydrated position and a just-simulated one agree instead of the
 * position carrying a frozen persisted health factor while the price moves.
 *
 * `collateralPriceOverrideUsd` defaults to the live market price so the read path stays
 * deterministic in tests (pass the price explicitly) yet reflects the current oracle in
 * production. A non-finite/non-positive override falls back to the market price.
 */
export function revalueMultiplyPosition(
  position: MultiplyPosition,
  market: MultiplyMarketRecord,
  collateralPriceOverrideUsd?: number,
): MultiplyPosition {
  const collateralPriceUsd =
    collateralPriceOverrideUsd != null && Number.isFinite(collateralPriceOverrideUsd) && collateralPriceOverrideUsd > 0
      ? collateralPriceOverrideUsd
      : market.collateralAsset.priceUsd
  const collateralValueUsd = position.collateralAmount * collateralPriceUsd
  const debtValueUsd = position.debtValueUsd
  const ltv = calculateMultiplyLtv(debtValueUsd, collateralValueUsd)
  const healthFactor = calculateMultiplyHealthFactor(collateralValueUsd, debtValueUsd, market.risk.liquidationThreshold)
  const liquidationPrice = calculateLiquidationPrice({
    debtValueUsd,
    collateralAmount: position.collateralAmount,
    liquidationThreshold: market.risk.liquidationThreshold,
  })
  // Recompute Net APY from the market's live economics with the same formula the multiply
  // page/detail/action use — never trust the persisted `position.netApy`, which the sandbox
  // seeds to 0 and never refreshes (that stale 0 is what left the dashboard reading 0.00%).
  const netApy = calculateNetApy({
    supplyApy: market.economics.supplyApy,
    borrowApy: market.economics.borrowApy,
    finalCollateralValueUsd: collateralValueUsd,
    debtValueUsd,
    initialCollateralValueUsd: Math.max(1, collateralValueUsd - debtValueUsd),
  })

  return {
    ...position,
    collateralValueUsd,
    ltv,
    healthFactor,
    liquidationPrice,
    netApy,
  }
}

function emptyBefore() {
  return {
    collateralValueUsd: 0,
    debtValueUsd: 0,
    ltv: 0,
    healthFactor: "infinity" as const,
    multiplier: 1,
    liquidationPrice: null,
  }
}

export function simulateMultiply(params: {
  market: MultiplyMarketRecord
  collateralAmount: number
  selectedMultiplier: number
  existingPosition?: MultiplyPosition | null
  collateralPriceOverrideUsd?: number
  /** True when the collateral oracle price is stale/unavailable — blocks the leverage open. */
  collateralPriceStale?: boolean
}): MultiplySimulation {
  const {
    market,
    collateralAmount,
    selectedMultiplier,
    existingPosition,
    collateralPriceOverrideUsd,
    collateralPriceStale,
  } = params
  const collateralPriceUsd =
    collateralPriceOverrideUsd != null && Number.isFinite(collateralPriceOverrideUsd) && collateralPriceOverrideUsd > 0
      ? collateralPriceOverrideUsd
      : market.collateralAsset.priceUsd
  // Reprice the existing position at this SAME live collateral price before blending it with
  // the new deposit. The persisted position can still carry collateralValueUsd from the stale
  // catalog fixture price (positions aren't re-priced on every hydration tick), so combining
  // it un-repriced with a live-priced new deposit understated the resulting health factor — a
  // small top-up barely moved that understated figure and stayed blocked ("Action unavailable"),
  // while a large one dragged the blended figure back up and passed.
  const repricedExisting = existingPosition
    ? revalueMultiplyPosition(existingPosition, market, collateralPriceUsd)
    : null
  const initialCollateralValueUsd = collateralAmount * collateralPriceUsd
  const priceImpactPct = calculatePriceImpact({
    baseImpact: DEFAULT_BASE_IMPACT,
    multiplier: selectedMultiplier,
    availableLiquidityUsd: market.economics.availableLiquidityUsd,
    collateralValueUsd: initialCollateralValueUsd,
  })

  const theoreticalMaxMultiplier = calculateTheoreticalMaxMultiplier(market.risk.maxLtv)
  const safeMaxMultiplier = calculateSafeMaxMultiplier({
    publicMaxMultiplier: market.risk.publicMaxMultiplier,
    theoreticalMaxMultiplier,
    minHealthFactor: market.risk.minHealthFactor,
    liquidationThreshold: market.risk.liquidationThreshold,
  })

  const swapEfficiency = Math.max(0, 1 - priceImpactPct)
  const loop = simulateCollateralLoop({
    initialCollateralUsd: initialCollateralValueUsd,
    targetMultiplier: selectedMultiplier,
    maxLtv: market.risk.maxLtv,
    swapEfficiency,
  })

  const newCollateralValueUsd = loop.collateralUsd
  const newDebtValueUsd = loop.debtUsd
  const existingCollateralValueUsd = repricedExisting?.collateralValueUsd ?? 0
  const existingDebtValueUsd = repricedExisting?.debtValueUsd ?? 0
  const finalCollateralValueUsd = existingCollateralValueUsd + newCollateralValueUsd
  const debtValueUsd = existingDebtValueUsd + newDebtValueUsd
  const finalCollateralAmount = (repricedExisting?.collateralAmount ?? 0) + newCollateralValueUsd / collateralPriceUsd
  const equityValueUsd = finalCollateralValueUsd - debtValueUsd
  const effectiveMultiplier = equityValueUsd > 0 ? finalCollateralValueUsd / equityValueUsd : loop.achievedMultiplier
  const ltv = calculateMultiplyLtv(debtValueUsd, finalCollateralValueUsd)
  const healthFactor = calculateMultiplyHealthFactor(
    finalCollateralValueUsd,
    debtValueUsd,
    market.risk.liquidationThreshold,
  )
  const liquidationPrice = calculateLiquidationPrice({
    debtValueUsd,
    collateralAmount: finalCollateralAmount,
    liquidationThreshold: market.risk.liquidationThreshold,
  })
  const netApy = calculateNetApy({
    supplyApy: market.economics.supplyApy,
    borrowApy: market.economics.borrowApy,
    finalCollateralValueUsd,
    debtValueUsd,
    initialCollateralValueUsd: Math.max(1, finalCollateralValueUsd - debtValueUsd),
  })
  const maxLeverageApy = calculateMaxLeverageApy({
    supplyApy: market.economics.supplyApy,
    borrowApy: market.economics.borrowApy,
    safeMaxMultiplier,
  })

  const before = repricedExisting
    ? {
        collateralValueUsd: repricedExisting.collateralValueUsd,
        debtValueUsd: repricedExisting.debtValueUsd,
        ltv: repricedExisting.ltv,
        healthFactor: repricedExisting.healthFactor,
        multiplier: repricedExisting.multiplier,
        liquidationPrice: repricedExisting.liquidationPrice,
      }
    : emptyBefore()

  const validation = validateMultiplyAction({
    selectedMultiplier,
    achievedMultiplier: loop.achievedMultiplier,
    loopSteps: loop.loops,
    theoreticalMaxMultiplier,
    publicMaxMultiplier: market.risk.publicMaxMultiplier,
    safeMaxMultiplier,
    recommendedMaxMultiplier: market.risk.recommendedMaxMultiplier,
    minHealthFactor: market.risk.minHealthFactor,
    maxLtv: market.risk.maxLtv,
    healthFactor,
    ltv,
    debtValueUsd,
    initialCollateralValueUsd,
    priceImpactPct,
    maxAllowedPriceImpact: MAX_ALLOWED_PRICE_IMPACT,
    netApy,
    supplyApy: market.economics.supplyApy,
    borrowApy: market.economics.borrowApy,
    liquidationPrice,
    collateralPriceUsd,
    oracleStale: collateralPriceStale,
  })

  return {
    action: "multiply",
    loopCount: loop.loops,
    input: { collateralAmount, selectedMultiplier },
    before,
    after: {
      collateralValueUsd: finalCollateralValueUsd,
      collateralAmount: finalCollateralAmount,
      debtValueUsd,
      ltv,
      healthFactor,
      multiplier: effectiveMultiplier,
      liquidationPrice,
      priceDropToLiquidationPct: calculatePriceDropToLiquidationPct(liquidationPrice, collateralPriceUsd),
    },
    economics: {
      supplyApy: market.economics.supplyApy,
      borrowApy: market.economics.borrowApy,
      netApy,
      maxLeverageApy,
      priceImpactPct,
    },
    limits: {
      maxLtv: market.risk.maxLtv,
      liquidationThreshold: market.risk.liquidationThreshold,
      theoreticalMaxMultiplier,
      safeMaxMultiplier,
      publicMaxMultiplier: market.risk.publicMaxMultiplier,
      recommendedMaxMultiplier: market.risk.recommendedMaxMultiplier,
      minHealthFactor: market.risk.minHealthFactor,
    },
    validation,
  }
}

export function simulateDeleverage(params: {
  market: MultiplyMarketRecord
  position: MultiplyPosition
  targetMultiplier: number
  repayAmountUsd?: number
  collateralPriceOverrideUsd?: number
}): DeleverageSimulation {
  const { market, position, targetMultiplier, repayAmountUsd, collateralPriceOverrideUsd } = params
  const collateralPriceUsd =
    collateralPriceOverrideUsd != null && Number.isFinite(collateralPriceOverrideUsd) && collateralPriceOverrideUsd > 0
      ? collateralPriceOverrideUsd
      : market.collateralAsset.priceUsd
  // Reprice the position at this live price before sizing the unwind — see simulateMultiply's
  // repricedExisting. A stale, catalog-fixture-priced position doesn't just misreport health
  // factor here; it also sizes how much collateral/debt to unwind to reach the target multiplier.
  const repriced = revalueMultiplyPosition(position, market, collateralPriceUsd)
  const currentCollateralValueUsd = repriced.collateralValueUsd
  const currentDebtValueUsd = repriced.debtValueUsd
  const currentMultiplier = repriced.multiplier

  const priceImpactPct = calculatePriceImpact({
    baseImpact: DEFAULT_BASE_IMPACT,
    multiplier: currentMultiplier,
    availableLiquidityUsd: market.economics.availableLiquidityUsd,
    collateralValueUsd: currentCollateralValueUsd,
  })

  const swapEfficiency = Math.max(0, 1 - priceImpactPct)
  const unwind = simulateDeleverageToTarget({
    collateralUsd: currentCollateralValueUsd,
    debtUsd: currentDebtValueUsd,
    targetMultiplier,
    swapEfficiency,
    repayAmountUsd,
  })

  const collateralToUnwindUsd = unwind.collateralUnwoundUsd
  const effectiveRepayUsd = unwind.debtRepaidUsd
  const newDebtValueUsd = unwind.debtUsd
  const newCollateralValueUsd = unwind.collateralUsd
  const targetDebtValueUsd = Math.max(0, newDebtValueUsd)
  const debtToRepayUsd = currentDebtValueUsd - newDebtValueUsd
  const newCollateralAmount = newCollateralValueUsd / collateralPriceUsd
  const newEquityValueUsd = newCollateralValueUsd - newDebtValueUsd
  const newMultiplier = newEquityValueUsd > 0 ? newCollateralValueUsd / newEquityValueUsd : 1
  const newLtv = calculateMultiplyLtv(newDebtValueUsd, newCollateralValueUsd)
  const newHealthFactor = calculateMultiplyHealthFactor(
    newCollateralValueUsd,
    newDebtValueUsd,
    market.risk.liquidationThreshold,
  )
  const newLiquidationPrice = calculateLiquidationPrice({
    debtValueUsd: newDebtValueUsd,
    collateralAmount: newCollateralAmount,
    liquidationThreshold: market.risk.liquidationThreshold,
  })
  const newNetApy = calculateNetApy({
    supplyApy: market.economics.supplyApy,
    borrowApy: market.economics.borrowApy,
    finalCollateralValueUsd: newCollateralValueUsd,
    debtValueUsd: newDebtValueUsd,
    initialCollateralValueUsd: Math.max(1, newCollateralValueUsd - newDebtValueUsd),
  })

  const validation = validateDeleverageAction({
    targetMultiplier,
    currentMultiplier,
    targetDebtValueUsd,
    currentDebtValueUsd,
    newHealthFactor,
    minHealthFactor: market.risk.minHealthFactor,
    priceImpactPct,
    maxAllowedPriceImpact: MAX_ALLOWED_PRICE_IMPACT,
  })

  return {
    action: "deleverage",
    input: { currentMultiplier, targetMultiplier },
    before: {
      collateralValueUsd: currentCollateralValueUsd,
      debtValueUsd: currentDebtValueUsd,
      ltv: repriced.ltv,
      healthFactor: repriced.healthFactor,
      multiplier: currentMultiplier,
      liquidationPrice: repriced.liquidationPrice,
    },
    after: {
      collateralValueUsd: newCollateralValueUsd,
      collateralAmount: newCollateralAmount,
      debtValueUsd: newDebtValueUsd,
      debtRepaidUsd: debtToRepayUsd,
      collateralUnwoundUsd: collateralToUnwindUsd,
      ltv: newLtv,
      healthFactor: newHealthFactor,
      multiplier: newMultiplier,
      liquidationPrice: newLiquidationPrice,
    },
    economics: {
      priceImpactPct,
      effectiveRepayUsd,
      netApy: newNetApy,
    },
    validation,
  }
}
