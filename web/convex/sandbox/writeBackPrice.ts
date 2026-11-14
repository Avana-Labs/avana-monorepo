/**
 * Unit price used to derive the token `amount` written back for a product-balance row.
 *
 * The row's own implied price (`valueUsd / amount`) is preferred so `amount` stays consistent with
 * the row's history — but only when it is plausibly correct. A USD-in-amount row (a create with no
 * price fell back to $1, or a debt row that stored USD in `amount`) implies a unit price of exactly
 * 1; trusting that re-derives `amount = valueUsd / 1 = valueUsd` on every subsequent write, so the
 * row never self-heals. When the implied price carries the ≈1 units-error signature against an oracle
 * that is NOT ≈1, or disagrees with the oracle beyond a plausible drift band, use the oracle so the
 * next write heals `amount` to a real token quantity. Falls back to the implied price when the oracle
 * is unavailable (never worse than today's behavior), and to the oracle when there is no implied price.
 */
export const WRITE_BACK_DRIFT_BAND = { min: 0.1, max: 10 } as const
export const WRITE_BACK_USD_PEG_TOLERANCE = 0.05

export function resolveWriteBackPriceUsd(impliedPriceUsd: number | null, oraclePriceUsd: number | null): number | null {
  if (impliedPriceUsd != null && Number.isFinite(impliedPriceUsd) && impliedPriceUsd > 0) {
    if (oraclePriceUsd == null || !Number.isFinite(oraclePriceUsd) || oraclePriceUsd <= 0) {
      return impliedPriceUsd
    }
    const impliedIsUsdLike = Math.abs(impliedPriceUsd - 1) < 1e-4
    const oracleIsUsdLike = Math.abs(oraclePriceUsd - 1) <= WRITE_BACK_USD_PEG_TOLERANCE
    if (impliedIsUsdLike && !oracleIsUsdLike) return oraclePriceUsd
    const scale = oraclePriceUsd / impliedPriceUsd
    if (!Number.isFinite(scale) || scale < WRITE_BACK_DRIFT_BAND.min || scale > WRITE_BACK_DRIFT_BAND.max) {
      return oraclePriceUsd
    }
    return impliedPriceUsd
  }
  return oraclePriceUsd
}
