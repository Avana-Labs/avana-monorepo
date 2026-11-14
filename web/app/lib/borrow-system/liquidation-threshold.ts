/**
 * Single client-side source for a collateral liquidation threshold from a market's collateral
 * factor. In Aave V4 the liquidation threshold equals the collateral factor
 * (`MarketView.liquidationThresholdBps == collateralFactorBps`, REQ-LENS-045), so the spread is 0.
 */
export const LIQUIDATION_THRESHOLD_SPREAD_PCT = 0
export const LIQUIDATION_THRESHOLD_CAP_PCT = 95

/** Implied liquidation threshold (%) for a given max-LTV/collateral factor (%). */
export function liquidationThresholdPctFromMaxLtvPct(maxLtvPct: number): number {
  return Math.min(maxLtvPct + LIQUIDATION_THRESHOLD_SPREAD_PCT, LIQUIDATION_THRESHOLD_CAP_PCT)
}
