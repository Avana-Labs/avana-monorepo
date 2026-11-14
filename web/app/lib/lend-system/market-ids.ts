/** Route id of a Lend market for a token symbol, when no services/convex slug is at hand. */
export function resolveLendMarketId(symbol: string) {
  return symbol.toLowerCase().replace(/[^a-z0-9]/g, "")
}
