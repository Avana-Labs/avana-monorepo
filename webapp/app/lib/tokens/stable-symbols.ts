const STABLE_SYMBOLS = new Set([
  "USDC",
  "USDT",
  "GHO",
  "DAI",
  "USDS",
  "EURC",
  "FRXUSD",
  "USDG",
  "RLUSD",
  "CRVUSD",
  "PYUSD",
])

/** True for a USD/EUR stablecoin symbol (display grouping only). */
export function isStableSymbol(symbol: string): boolean {
  return STABLE_SYMBOLS.has(symbol.trim().toUpperCase())
}
