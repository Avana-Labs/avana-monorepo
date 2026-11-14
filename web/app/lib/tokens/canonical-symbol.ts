/**
 * Canonical display casing for token symbols, shared by the multiply catalog and the Convex
 * balance writers. Must stay a PURE module (no runtime imports) so Convex can bundle it.
 *
 * Mirrors the keys of MULTIPLY_TOKEN_LOGOS in app/lib/multiply-sim.ts — keep the two in sync.
 * Unlisted symbols fall back to blind uppercase, which is already canonical for tickers like
 * ETH/USDC/WBTC and for market slugs.
 */
const CANONICAL_TOKEN_SYMBOLS = [
  "ETH",
  "stETH",
  "wstETH",
  "rETH",
  "cbETH",
  "USDT",
  "USDC",
  "DAI",
  "GHO",
  "crvUSD",
  "EURC",
  "WBTC",
  "cbBTC",
  "AAVE",
  "UNI",
  "CRV",
] as const

type CanonicalTokenSymbol = (typeof CANONICAL_TOKEN_SYMBOLS)[number]

const CANONICAL_BY_LOWER: ReadonlyMap<string, CanonicalTokenSymbol> = new Map(
  CANONICAL_TOKEN_SYMBOLS.map((symbol) => [symbol.toLowerCase(), symbol] as const),
)

/** Canonical casing for a known token symbol (case-insensitive), or null when the symbol is unknown. */
export function canonicalTokenSymbol(symbol: string): CanonicalTokenSymbol | null {
  return CANONICAL_BY_LOWER.get(symbol.trim().toLowerCase()) ?? null
}

/** Canonical casing when the symbol is known, else the blind uppercase used before (safe for slugs). */
export function canonicalTokenSymbolOrUpper(symbol: string): string {
  return canonicalTokenSymbol(symbol) ?? symbol.trim().toUpperCase()
}
