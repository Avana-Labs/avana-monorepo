/**
 * The SINGLE LP-collateral valuation model: LPPriceUSD = Σ (weightᵢ × TokenPriceUSDᵢ), with
 * Σ weightᵢ = 1 and any number of constituents. Deliberately NOT the constant-product
 * 2·√(P0·P1), and no reserves / LP-total-supply derivation.
 *
 * One unpriced constituent makes the whole LP price `unavailable` — never a number derived
 * from incomplete data. Float here (display/collateral USD); position math stays bigint
 * fixed-point (credit-engine/units.ts).
 */

/** A pool constituent with its NORMALIZED weight (fraction of 1). */
export type WeightedConstituent = { symbol: string; weight: number }

/** Weights must sum to 1 within this tolerance (float thirds never land exactly on 1). */
export const WEIGHT_SUM_TOLERANCE = 1e-6

type LpPriceResult =
  { ok: true; priceUsd: number } | { ok: false; reason: "empty" | "weights" | "unpriced"; detail?: string }

/**
 * Weighted-average LP token USD price. `priceOf` resolves a constituent symbol to its
 * canonical USD price (undefined when unpriced). Returns `unavailable` — never a partial
 * number — when there are no constituents, the weights don't sum to 1, or any leg is unpriced.
 */
export function lpTokenPriceUsd(
  constituents: readonly WeightedConstituent[],
  priceOf: (symbol: string) => number | undefined,
): LpPriceResult {
  if (constituents.length === 0) return { ok: false, reason: "empty" }

  let weightSum = 0
  for (const c of constituents) {
    if (!Number.isFinite(c.weight) || c.weight < 0) {
      return { ok: false, reason: "weights", detail: `bad weight ${c.weight} for ${c.symbol}` }
    }
    weightSum += c.weight
  }
  if (Math.abs(weightSum - 1) > WEIGHT_SUM_TOLERANCE) {
    return { ok: false, reason: "weights", detail: `weights sum to ${weightSum}, expected 1` }
  }

  let priceUsd = 0
  for (const c of constituents) {
    const p = priceOf(c.symbol)
    if (p === undefined || !Number.isFinite(p) || p <= 0) {
      return { ok: false, reason: "unpriced", detail: c.symbol }
    }
    priceUsd += c.weight * p
  }
  return { ok: true, priceUsd }
}

/**
 * Normalize raw proportional weights into fractions summing to 1. Author pool weights as small
 * integers — equal-weight `[1,1,1]`, 50/25/25 as `[2,1,1]`, 80/20 as `[4,1]` — and this yields
 * exact fractions (unlike integer basis-points, which can't represent equal thirds exactly).
 */
export function normalizeWeights<T extends { weight: number }>(items: readonly T[]): T[] {
  const total = items.reduce((sum, i) => sum + i.weight, 0)
  if (!(total > 0)) throw new Error("pool weights must be positive and sum to > 0")
  return items.map((i) => ({ ...i, weight: i.weight / total }))
}

/** SuppliedUSD = SuppliedLPAmount × LPPriceUSD. Rejects a negative/invalid LP amount. */
export function suppliedUsd(lpAmount: number, lpPriceUsd: number): number {
  if (!Number.isFinite(lpAmount) || lpAmount < 0) throw new Error(`invalid LP amount: ${lpAmount}`)
  return lpAmount * lpPriceUsd
}
