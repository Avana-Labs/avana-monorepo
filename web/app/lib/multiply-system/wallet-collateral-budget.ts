import { canonicalPriceUsd } from "@/app/lib/prices/canonical"

// The open flow caps collateral at a per-market USD bucket in `walletBalancesUsd`. Convex only
// writes an explicit multiplyBalances row when a prior multiply flow parked collateral there, so
// when none exists the bucket is derived from the wallet's real liquid holdings of that token —
// otherwise a wallet merely holding the token blocks with "Max 0".

/** A wallet's liquid holding of a single token (walletLiquidBalances view, minimally typed). */
type MultiplyLiquidHolding = {
  symbol: string
  valueUsd: number
  amount?: number
}

/**
 * Per-market collateral budget (USD), keyed by market id. Explicit `multiplyBalances` "available"
 * buckets always win; a missing or zero bucket falls back to the wallet's liquid holding of that
 * market's collateral token, matched by symbol case-insensitively.
 */
export function deriveMultiplyCollateralBudgetUsd({
  explicitBucketsUsd,
  markets,
  liquidHoldings,
}: {
  explicitBucketsUsd: Record<string, number>
  markets: Record<string, { collateralAsset: { symbol: string } }>
  liquidHoldings: readonly MultiplyLiquidHolding[]
}): Record<string, number> {
  // Wallet tokens are worth amount × today's price; `valueUsd` is what they cost, so 119.05 AAVE
  // bought at $105 read as 90.33 AAVE of budget at $138.
  const liquidUsdBySymbol = new Map<string, number>()
  for (const holding of liquidHoldings) {
    const symbol = holding?.symbol?.toLowerCase()
    if (!symbol) continue
    // The same live price store the Multiply form divides the budget by.
    const livePriceUsd = canonicalPriceUsd(symbol)
    const holdingUsd =
      holding.amount !== undefined && holding.amount > 0 && livePriceUsd !== undefined
        ? holding.amount * livePriceUsd
        : holding.valueUsd
    if (!Number.isFinite(holdingUsd) || holdingUsd <= 0) continue
    liquidUsdBySymbol.set(symbol, (liquidUsdBySymbol.get(symbol) ?? 0) + holdingUsd)
  }

  const buckets: Record<string, number> = { ...explicitBucketsUsd }
  for (const [marketId, market] of Object.entries(markets)) {
    if ((buckets[marketId] ?? 0) > 0) continue
    const symbol = market.collateralAsset?.symbol?.toLowerCase()
    if (!symbol) continue
    const liquidUsd = liquidUsdBySymbol.get(symbol)
    if (liquidUsd && liquidUsd > 0) buckets[marketId] = liquidUsd
  }
  return buckets
}
