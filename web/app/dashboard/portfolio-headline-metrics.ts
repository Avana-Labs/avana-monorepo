/**
 * Pure helpers for the Your Dashboard headline cards (Net Value / Net APY).
 * Equity-weighted blending only — never arithmetic-average product APYs.
 */

type PortfolioApyLeg = {
  /** Net equity USD attributed to this product (collateral − debt for borrow/multiply). */
  equityUsd: number
  /** Product Net APY in percent units (e.g. 5.2 means 5.2%). */
  netApyPct: number
}

/**
 * Value-weighted portfolio Net APY across productive legs.
 * Idle wallet cash is intentionally excluded (matches Convex computePortfolioNetApyPct).
 * Zero / negative equity legs are skipped so underwater books do not invert the blend.
 */
export function blendEquityWeightedNetApyPct(legs: readonly PortfolioApyLeg[]): number {
  let weight = 0
  let weighted = 0
  for (const leg of legs) {
    if (!(leg.equityUsd > 0) || !Number.isFinite(leg.netApyPct)) continue
    weight += leg.equityUsd
    weighted += leg.equityUsd * leg.netApyPct
  }
  return weight > 0 ? weighted / weight : 0
}

/**
 * Prefer the live client blend whenever it was computed (including a genuine 0%).
 * Fall back to Convex only when the client blend is unavailable (null).
 */
export function resolveDashboardNetApyPct(clientBlendPct: number | null, convexBlendPct: number | undefined): number {
  if (clientBlendPct != null && Number.isFinite(clientBlendPct)) return clientBlendPct
  return convexBlendPct ?? 0
}
