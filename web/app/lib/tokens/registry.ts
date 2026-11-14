/**
 * Token registry — the single place a NEW token's display metadata is declared (name, icon,
 * ticker casing), for tokens the hand-written icon maps do not cover. Must stay a leaf module
 * (no app-side imports) to avoid cycles. Prices never come from here: they come from the live
 * price snapshot.
 */

type TokenDef = {
  /** Canonical UPPERCASE key. */
  symbol: string
  /** User-facing ticker casing. Defaults to `symbol`. */
  displaySymbol?: string
  name: string
  /** Full public path to the icon. */
  iconPath?: string
  bgClass?: string
  textClass?: string
  decimals?: number
  /** Whether the token is swap-routable. Default false → metadata-only. */
  swapEnabled?: boolean
}

const TOKEN_REGISTRY: Record<string, TokenDef> = {}

export function getRegistryToken(symbol: string): TokenDef | undefined {
  if (!symbol) return undefined
  return TOKEN_REGISTRY[symbol.trim().toUpperCase()]
}

/** Full public icon path for a registered symbol, or undefined. */
export function registryIconPath(symbol: string): string | undefined {
  return getRegistryToken(symbol)?.iconPath
}

/** User-facing ticker casing for a registered symbol, or undefined. */
export function registryDisplaySymbol(symbol: string): string | undefined {
  const token = getRegistryToken(symbol)
  if (!token) return undefined
  return token.displaySymbol ?? token.symbol
}
