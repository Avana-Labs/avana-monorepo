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

const STOCK_BG = "bg-slate-100"
const STOCK_TEXT = "text-slate-700"

/**
 * Tokenized-stock underlyings and their icons (`public/stock-Icons/`). `c: true` also registers the Aerodrome "…c"
 * variant of the same underlying (key "NVDAC", shown "NVDAc").
 */
const STOCK_UNDERLYINGS: ReadonlyArray<{ sym: string; name: string; icon: string; c: boolean }> = [
  { sym: "NVDA", name: "NVIDIA", icon: "nvidia", c: true },
  { sym: "AAPL", name: "Apple", icon: "apple", c: true },
  { sym: "GOOGL", name: "Alphabet", icon: "google", c: true },
  { sym: "META", name: "Meta Platforms", icon: "meta", c: true },
  { sym: "AMZN", name: "Amazon", icon: "amazon", c: true },
  { sym: "MSFT", name: "Microsoft", icon: "microsoft", c: true },
  { sym: "TSLA", name: "Tesla", icon: "tesla", c: true },
  { sym: "SPCX", name: "SpaceX", icon: "spacex", c: true },
  { sym: "SNDK", name: "Sandisk", icon: "sandisk", c: true },
  { sym: "AMC", name: "AMC Entertainment", icon: "amc", c: false },
  { sym: "MU", name: "Micron Technology", icon: "micron", c: false },
]

function stockEntry(sym: string, name: string, icon: string): TokenDef {
  return {
    symbol: sym,
    name,
    iconPath: `/stock-Icons/${icon}.png`,
    bgClass: STOCK_BG,
    textClass: STOCK_TEXT,
    decimals: 18,
    swapEnabled: false,
  }
}

function buildRegistry(): Record<string, TokenDef> {
  const out: Record<string, TokenDef> = {}
  for (const s of STOCK_UNDERLYINGS) {
    out[s.sym] = stockEntry(s.sym, s.name, s.icon)
    if (s.c) out[`${s.sym}C`] = { ...stockEntry(`${s.sym}C`, s.name, s.icon), displaySymbol: `${s.sym}c` }
  }
  return out
}

const TOKEN_REGISTRY: Record<string, TokenDef> = buildRegistry()

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
