const CONVEX_PRICE_MIN_CONFIDENCE = 0.8
export const CONVEX_PRICE_INVALID_AFTER_MS = 45 * 60 * 1000
const USD_PEGGED_SYMBOLS = new Set(["USDC", "USDT", "DAI", "GHO", "CRVUSD", "USDE", "FRXUSD", "USDG", "RLUSD"])
const USD_PEGGED_MIN_PRICE = 0.5
const USD_PEGGED_MAX_PRICE = 1.5

type ConvexPriceRow = {
  symbol: string
  priceUsd: number
  confidence?: number
  status?: "fresh" | "stale" | "invalid"
  updatedAt: number
}

export function isUsableConvexPrice(
  row: ConvexPriceRow,
  now = Date.now(),
  invalidAfterMs = CONVEX_PRICE_INVALID_AFTER_MS,
) {
  if (!row.symbol.trim() || !Number.isFinite(row.priceUsd) || row.priceUsd <= 0) return false
  if (
    USD_PEGGED_SYMBOLS.has(row.symbol.trim().toUpperCase()) &&
    (row.priceUsd < USD_PEGGED_MIN_PRICE || row.priceUsd > USD_PEGGED_MAX_PRICE)
  ) {
    return false
  }
  if (row.status === "invalid") return false
  if (typeof row.confidence === "number" && row.confidence < CONVEX_PRICE_MIN_CONFIDENCE) return false
  if (!Number.isFinite(row.updatedAt) || now - row.updatedAt >= invalidAfterMs) return false
  return true
}

export function validatedConvexPriceMap(
  rows: readonly ConvexPriceRow[],
  now = Date.now(),
  invalidAfterMs = CONVEX_PRICE_INVALID_AFTER_MS,
) {
  const prices: Record<string, number> = {}
  for (const row of rows) {
    if (isUsableConvexPrice(row, now, invalidAfterMs)) prices[row.symbol.trim().toLowerCase()] = row.priceUsd
  }
  return prices
}
