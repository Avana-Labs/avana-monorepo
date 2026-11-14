/**
 * Single client-side source for deriving a collateral liquidation threshold from a pool's
 * max-LTV / collateral factor when the pool carries no explicit threshold.
 *
 * The liquidation threshold sits a fixed spread ABOVE the collateral factor (which only
 * sizes borrow capacity) and is capped. Every client surface that needs an implied LT — the
 * credit engine's `estimateLiquidationThresholdWad`, the portfolio live-source HF — routes
 * through this so they can't drift apart. The Convex persist gate mirrors the same numbers
 * (convex/sandbox/transactions.ts `liquidationThresholdFromMaxLtv`), hand-synced because
 * Convex can't import app/. Keeping them equal is what makes confirm == persist. (#12)
 */
export const LIQUIDATION_THRESHOLD_SPREAD_PCT = 10
export const LIQUIDATION_THRESHOLD_CAP_PCT = 95

/** Implied liquidation threshold (%) for a given max-LTV/collateral factor (%). */
export function liquidationThresholdPctFromMaxLtvPct(maxLtvPct: number): number {
  return Math.min(maxLtvPct + LIQUIDATION_THRESHOLD_SPREAD_PCT, LIQUIDATION_THRESHOLD_CAP_PCT)
}
