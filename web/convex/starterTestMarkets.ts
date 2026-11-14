import type { MutationCtx } from "./_generated/server"

/**
 * A complete starter catalog for tests: enough markets in every bucket to satisfy
 * STARTER_BUCKETS, each with a UNIQUE symbol so it can carry its own price row. The
 * onboarding claim path fails closed on an incomplete catalog (missing buckets or a
 * chosen leg with no positive price), so tests seed BOTH markets and matching
 * `tokenPrices` via `seedStarterTestMarkets`.
 */
export const STARTER_TEST_MARKETS = [
  ...Array.from({ length: 12 }, (_, index) => ({
    scope: "asset" as const,
    slug: `asset-${index}`,
    name: `Asset ${index}`,
    symbol: index === 0 ? "USDC" : `ASSET${index}`,
  })),
  ...Array.from({ length: 8 }, (_, index) => ({
    scope: "pool" as const,
    slug: `pool-${index}`,
    name: `Pool ${index}`,
    symbol: `POOL${index}`,
  })),
  ...Array.from({ length: 8 }, (_, index) => ({
    scope: "lend" as const,
    slug: `lend-${index}`,
    name: `Lend ${index}`,
    symbol: `LEND${index}`,
  })),
  ...Array.from({ length: 6 }, (_, index) => ({
    scope: "multiply" as const,
    slug: `multiply-${index}`,
    name: `Multiply ${index}`,
    // Distinct per-index collateral symbol so each multiply market has its own price.
    symbol: `MULT${index}`,
  })),
]

/** Deterministic positive test price for a market symbol (USDC pinned to $1). */
export function starterTestPriceFor(symbol: string): number {
  const normalized = symbol.toLowerCase()
  if (normalized === "usdc") return 1
  // Stable, distinctive, > 0 price per symbol so token-quantity math is easy to assert.
  let hash = 2166136261
  for (let i = 0; i < normalized.length; i++) {
    hash ^= normalized.charCodeAt(i)
    hash = Math.imul(hash, 16777619)
  }
  return 100 + ((hash >>> 0) % 900) // [100, 999]
}

/**
 * Seed the full starter catalog AND a matching `tokenPrices` row per symbol so the
 * onboarding claim's fail-closed catalog gate is satisfied. Use this in tests instead of
 * inserting `markets` alone.
 */
export async function seedStarterTestMarkets(ctx: MutationCtx): Promise<void> {
  const seenSymbols = new Set<string>()
  for (const market of STARTER_TEST_MARKETS) {
    await ctx.db.insert("markets", { ...market, chainId: 1, createdAt: 0 })
    const symbol = market.symbol.toLowerCase()
    if (seenSymbols.has(symbol)) continue
    seenSymbols.add(symbol)
    await ctx.db.insert("tokenPrices", {
      symbol,
      llamaId: `test:${symbol}`,
      priceUsd: starterTestPriceFor(market.symbol),
      source: "test",
      updatedAt: 0,
    })
  }
}
