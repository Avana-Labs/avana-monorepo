/**
 * Decimal-safe valuation of an 18-decimal LP/token notional at a USD price.
 *
 * The engine holds collateral as 18-decimal bigints (1 token = 1e18). `Number(raw) / 1e18`
 * loses precision the moment `raw` exceeds 2^53 (~0.009 tokens), so the naive float product
 * `(Number(raw) / 1e18) * priceUsd` degrades the authoritative server solvency/liquidation
 * value for any non-trivial pledge. Multiply in bigint (raw × priceUsd6) and only scale down to
 * a JS number at the very end, where the usd6 magnitude is far below 2^53 for any realistic USD
 * amount (< ~$9e9). Calculation precision is bigint; UI rounding stays downstream.
 */

export const USD6_SCALE = 1_000_000n
export const TOKEN_WAD = 10n ** 18n

/**
 * USD value of an 18-decimal token notional at `priceUsd` (JS float USD/token). Returns 0 for a
 * non-positive/non-finite price or amount — callers decide whether that is an error.
 */
export function tokenNotionalToUsd(raw18: bigint, priceUsd: number): number {
  if (raw18 <= 0n || !Number.isFinite(priceUsd) || priceUsd <= 0) return 0
  const priceUsd6 = BigInt(Math.round(priceUsd * 1_000_000))
  const valueUsd6 = (raw18 * priceUsd6) / TOKEN_WAD
  return Number(valueUsd6) / 1_000_000
}
