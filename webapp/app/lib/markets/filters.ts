/**
 * Faceted market filters shared by Lend / Borrow: Chains, Hubs, Markets and Assets.
 *
 * Every page reduces its rows to a `FilterableItem` (which chains, hub, markets and assets the
 * row belongs to); the filter bar then only deals with ids. Facets combine with AND, the options
 * inside one facet with OR, and an empty facet means "no constraint".
 */

import { categorizeMarket, CATEGORY_CHIPS, type MarketCategory } from "@/app/lib/markets/category"
import { tokenDisplayName } from "@/app/lib/markets/token-names"

// ----- Chains ----------------------------------------------------------------

export type ChainId = "ethereum" | "base" | "local"

export type FilterOption<Id extends string = string> = {
  id: Id
  /** English label; translated at render time unless `brand` is set. */
  label: string
  /** Proper nouns (chains, DEXes) render as-is in every locale. */
  brand?: boolean
  iconSrc?: string
  /** Listed for the roadmap but no market uses it yet: shown disabled with a "Soon" tag. */
  soon?: boolean
}

export const CHAIN_OPTIONS: ReadonlyArray<FilterOption<ChainId>> = [
  { id: "ethereum", label: "Ethereum", brand: true, iconSrc: "/asset-icons/eth.png" },
  { id: "base", label: "Base", brand: true },
  { id: "local", label: "Local" },
]

/**
 * List rows do not carry their chain yet, so every row matches every chain option. Derive the
 * chain per row from services/convex `chainId` when the rows carry it.
 */
export const MARKET_CHAINS: readonly ChainId[] = ["ethereum", "base", "local"]

/** The chain filter id of an EVM chain id. */
export function chainFilterId(chainId: number | undefined): ChainId | null {
  if (chainId === 1) return "ethereum"
  if (chainId === 8453) return "base"
  if (chainId === 31337) return "local"
  return null
}

// ----- Hubs ------------------------------------------------------------------

export type HubId = "stable" | "correlated" | "volatile"

export const HUB_OPTIONS: ReadonlyArray<FilterOption<HubId>> = [
  { id: "stable", label: "Stable" },
  { id: "correlated", label: "Correlated" },
  { id: "volatile", label: "Volatile" },
]

/**
 * Risk hub from the market's tokens. Stable: every token is a stablecoin. Correlated: every token
 * tracks the same asset (the ETH family or the BTC family). Volatile: anything else.
 */
export function hubForSymbols(symbols: readonly string[]): HubId {
  const families = symbols.map((symbol) => categorizeMarket(symbol))
  if (families.length === 0) return "volatile"
  if (families.every((family) => family === "forex")) return "stable"
  if (families.every((family) => family === "eth") || families.every((family) => family === "btc")) return "correlated"
  return "volatile"
}

// ----- Markets ---------------------------------------------------------------

const categoryOptions = (product: "lend"): ReadonlyArray<FilterOption<MarketCategory>> =>
  CATEGORY_CHIPS[product]
    .filter((chip): chip is { id: MarketCategory; label: string } => chip.id !== "all")
    .map((chip) => ({ id: chip.id, label: chip.label }))

export const LEND_MARKET_OPTIONS = categoryOptions("lend")

/** The DEX (AMM protocol) a CDP Spoke accepts LP positions from. */
export type BorrowMarketId = "uniswap-v3" | "aerodrome-slipstream"

export const BORROW_MARKET_OPTIONS: ReadonlyArray<FilterOption<BorrowMarketId>> = [
  { id: "uniswap-v3", label: "Uniswap V3", brand: true, iconSrc: "/asset-icons/uni.png" },
  { id: "aerodrome-slipstream", label: "Aerodrome Slipstream", brand: true, iconSrc: "/asset-icons/aero.png" },
]

/** The DEX market of a row, from its DEX label or Spoke id. */
export function borrowMarketForSpoke(spokeOrDex: string): BorrowMarketId | null {
  const key = spokeOrDex.toLowerCase()
  if (key.includes("uni")) return "uniswap-v3"
  if (key.includes("aero") || key.includes("slipstream")) return "aerodrome-slipstream"
  return null
}

// ----- Assets ----------------------------------------------------------------

export type AssetTabId = "all" | "stable" | "eth" | "btc" | "other"

export const ASSET_TABS: ReadonlyArray<{ id: AssetTabId; label: string }> = [
  { id: "all", label: "All" },
  { id: "stable", label: "Stablecoins" },
  { id: "eth", label: "ETH" },
  { id: "btc", label: "BTC" },
  { id: "other", label: "Other" },
]

export function assetTabFor(symbol: string): Exclude<AssetTabId, "all"> {
  const family = categorizeMarket(symbol)
  if (family === "forex") return "stable"
  if (family === "eth" || family === "btc") return family
  return "other"
}

export type AssetOption = { symbol: string; name: string; tab: Exclude<AssetTabId, "all"> }

/** One option per symbol (case-insensitive), sorted by name then symbol. */
export function buildAssetOptions(entries: ReadonlyArray<{ symbol: string; name?: string }>): AssetOption[] {
  const bySymbol = new Map<string, AssetOption>()
  for (const entry of entries) {
    const key = entry.symbol.trim().toUpperCase()
    if (!key || bySymbol.has(key)) continue
    // A "name" that is just the symbol again is no name at all.
    const given = entry.name?.trim()
    const name = (given && given.toUpperCase() !== key ? given : undefined) ?? tokenDisplayName(key) ?? entry.symbol
    bySymbol.set(key, { symbol: entry.symbol.trim(), name, tab: assetTabFor(key) })
  }
  return [...bySymbol.values()].sort(
    (a, b) => a.name.localeCompare(b.name, "en") || a.symbol.localeCompare(b.symbol, "en"),
  )
}

// ----- Matching --------------------------------------------------------------

export type FacetId = "chains" | "hubs" | "markets" | "assets"

export type FilterableItem = {
  chains: readonly string[]
  hub: string
  markets: readonly string[]
  /** Uppercase token symbols. */
  assets: readonly string[]
}

export type MarketFilterState = Record<FacetId, readonly string[]>

export const EMPTY_MARKET_FILTERS: MarketFilterState = { chains: [], hubs: [], markets: [], assets: [] }

function itemValues(item: FilterableItem, facet: FacetId): readonly string[] {
  if (facet === "hubs") return [item.hub]
  if (facet === "assets") return item.assets
  return item[facet]
}

function facetSelection(state: MarketFilterState, facet: FacetId): readonly string[] {
  return facet === "assets" ? state.assets.map((symbol) => symbol.toUpperCase()) : state[facet]
}

export function matchesMarketFilters(item: FilterableItem, state: MarketFilterState, skip?: FacetId): boolean {
  return (["chains", "hubs", "markets", "assets"] as const).every((facet) => {
    if (facet === skip) return true
    const selected = facetSelection(state, facet)
    if (selected.length === 0) return true
    const values = itemValues(item, facet)
    return selected.some((id) => values.includes(id))
  })
}

/** Per-option counts for one facet, honouring every OTHER active facet (classic faceted search). */
export function facetCounts(
  items: readonly FilterableItem[],
  state: MarketFilterState,
  facet: FacetId,
): Map<string, number> {
  const counts = new Map<string, number>()
  for (const item of items) {
    if (!matchesMarketFilters(item, state, facet)) continue
    for (const value of new Set(itemValues(item, facet))) counts.set(value, (counts.get(value) ?? 0) + 1)
  }
  return counts
}

export function activeFilterCount(state: MarketFilterState): number {
  return state.chains.length + state.hubs.length + state.markets.length + state.assets.length
}

// ----- Row adapters ----------------------------------------------------------

export function lendFilterItem(symbol: string): FilterableItem {
  return {
    chains: MARKET_CHAINS,
    hub: hubForSymbols([symbol]),
    markets: [categorizeMarket(symbol)],
    assets: [symbol.toUpperCase()],
  }
}

/** Every token in a pool: the two display legs plus any extra constituents of 3+ token pools. */
export function borrowPoolSymbols(pool: {
  visuals: ReadonlyArray<{ symbol: string }>
  constituents?: ReadonlyArray<{ symbol: string }>
}): string[] {
  const seen = new Set<string>()
  const symbols: string[] = []
  for (const { symbol } of [...pool.visuals, ...(pool.constituents ?? [])]) {
    const key = symbol.trim().toUpperCase()
    if (!key || seen.has(key)) continue
    seen.add(key)
    symbols.push(symbol.trim())
  }
  return symbols
}

export function borrowPoolFilterItem(pool: {
  spoke: string
  dexId?: string
  visuals: ReadonlyArray<{ symbol: string }>
  constituents?: ReadonlyArray<{ symbol: string }>
}): FilterableItem {
  const symbols = borrowPoolSymbols(pool)
  const market = borrowMarketForSpoke(pool.dexId ?? pool.spoke)
  return {
    chains: MARKET_CHAINS,
    hub: hubForSymbols(symbols),
    markets: market ? [market] : [],
    assets: symbols.map((symbol) => symbol.toUpperCase()),
  }
}
