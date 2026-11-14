import { calculatePriceDropToLiquidationPct } from "./formulas"
import { MULTIPLY_ACTION_MAX_LEVERAGE } from "@/app/lib/multiply-system/leverage-limits"

export function validateMultiplyAction(params: {
  selectedMultiplier: number
  achievedMultiplier?: number
  loopSteps?: number
  theoreticalMaxMultiplier: number
  publicMaxMultiplier: number
  safeMaxMultiplier: number
  recommendedMaxMultiplier: number
  minHealthFactor: number
  maxLtv: number
  healthFactor: number | "infinity"
  ltv: number
  debtValueUsd: number
  initialCollateralValueUsd: number
  priceImpactPct: number
  maxAllowedPriceImpact: number
  netApy: number
  supplyApy: number
  borrowApy: number
  liquidationPrice: number | null
  collateralPriceUsd: number
  /**
   * Set when the collateral oracle price backing this leverage decision is stale/unavailable.
   * A leveraged open sized off a stale price can breach LTV/HF the moment the real price lands,
   * so block it rather than size against a number we can't trust. Optional so callers that don't
   * yet thread freshness are unaffected.
   */
  oracleStale?: boolean
}) {
  const errors: string[] = []
  const warnings: string[] = []

  if (params.oracleStale) {
    errors.push("Collateral price is stale — refresh before adjusting leverage.")
  }
  if (params.selectedMultiplier < 1) errors.push("Multiplier must be at least 1x.")
  if (params.selectedMultiplier > MULTIPLY_ACTION_MAX_LEVERAGE)
    errors.push(`Multiplier cannot exceed ${MULTIPLY_ACTION_MAX_LEVERAGE}x.`)
  if (params.selectedMultiplier > params.theoreticalMaxMultiplier) {
    warnings.push("Multiplier exceeds the theoretical maximum for this market.")
  }
  if (params.selectedMultiplier > params.publicMaxMultiplier) {
    errors.push("Multiplier exceeds the public maximum for this market.")
  }
  if (params.initialCollateralValueUsd <= 0) errors.push("Collateral amount must be positive.")
  if (
    params.achievedMultiplier != null &&
    params.selectedMultiplier > 1.05 &&
    params.achievedMultiplier < params.selectedMultiplier - 0.15
  ) {
    warnings.push(
      `Loop simulation reached ${params.achievedMultiplier.toFixed(1)}x instead of the requested ${params.selectedMultiplier.toFixed(1)}x.`,
    )
  }
  if (params.debtValueUsd <= 0 && params.selectedMultiplier > 1) {
    errors.push("Debt must be positive for leveraged positions.")
  }
  if (params.ltv > params.maxLtv) {
    errors.push("LTV exceeds the market maximum.")
  }
  if (params.healthFactor !== "infinity" && params.healthFactor < 1.0) {
    errors.push("Health factor is below the liquidation threshold.")
  } else if (params.healthFactor !== "infinity" && params.healthFactor < params.minHealthFactor) {
    // Between HF 1.0 and the market minimum the position is technically solvent but
    // opens already inside the at-risk band. Block it as hard as the sub-1.0 case
    // rather than merely warning — mirrors the maxLtv / publicMaxMultiplier errors.
    errors.push("Health factor is below the market minimum.")
  }
  if (params.priceImpactPct > params.maxAllowedPriceImpact) {
    errors.push("Estimated price impact is too high.")
  }

  if (params.selectedMultiplier > params.recommendedMaxMultiplier) {
    warnings.push("Selected multiplier exceeds the recommended maximum for this market.")
  } else if (params.selectedMultiplier > params.safeMaxMultiplier) {
    warnings.push("Selected multiplier exceeds the recommended safe maximum.")
  }
  if (params.healthFactor !== "infinity" && params.healthFactor < 1.5) {
    warnings.push("Health factor is below 1.5.")
  }
  const priceDrop = calculatePriceDropToLiquidationPct(params.liquidationPrice, params.collateralPriceUsd)
  if (priceDrop !== null && priceDrop < 0.2) {
    warnings.push("Price drop to liquidation is less than 20%.")
  }
  if (params.netApy <= 0) warnings.push("Estimated net APY is zero or negative.")
  if (params.borrowApy > params.supplyApy) {
    warnings.push("Borrow APY exceeds supply APY.")
  }

  return {
    allowed: errors.length === 0,
    errors,
    warnings,
  }
}

export function validateDeleverageAction(params: {
  targetMultiplier: number
  currentMultiplier: number
  targetDebtValueUsd: number
  currentDebtValueUsd: number
  newHealthFactor: number | "infinity"
  minHealthFactor: number
  priceImpactPct: number
  maxAllowedPriceImpact: number
}) {
  const errors: string[] = []
  const warnings: string[] = []

  if (params.targetMultiplier < 1) errors.push("Target multiplier must be at least 1x.")
  if (params.targetMultiplier >= params.currentMultiplier) {
    errors.push("Target multiplier must be lower than the current multiplier.")
  }
  if (params.targetDebtValueUsd < 0) errors.push("Target debt cannot be negative.")
  if (params.currentDebtValueUsd <= 0) errors.push("Position has no debt to deleverage.")
  if (params.priceImpactPct > params.maxAllowedPriceImpact) {
    errors.push("Estimated price impact is too high.")
  }

  if (params.newHealthFactor !== "infinity" && params.newHealthFactor < params.minHealthFactor) {
    warnings.push("Deleverage would leave health factor below the market minimum.")
  }
  if (params.priceImpactPct > 0.01) {
    warnings.push("Price impact is elevated for this deleverage.")
  }
  if (params.targetMultiplier > 1 && params.newHealthFactor !== "infinity" && params.newHealthFactor < 1.3) {
    warnings.push("Target multiplier remains close to liquidation.")
  }

  return {
    allowed: errors.length === 0,
    errors,
    warnings,
  }
}
