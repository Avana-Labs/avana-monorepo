/**
 * Faceted market filters shared by Lend / Borrow / Multiply: Chains, Hubs, Markets and Assets.
 *
 * Every page reduces its rows to a `FilterableItem` (which chains, hub, markets and assets the
 * row belongs to); the filter bar then only deals with ids. Facets combine with AND, the options
 * inside one facet with OR, and an empty facet means "no constraint".
 */

import { categorizeMarket, CATEGORY_CHIPS, type MarketCategory } from "@/app/lib/markets/category"
import { getRegistryToken } from "@/app/lib/tokens/registry"
import { tokenDisplayName } from "@/app/lib/markets/token-names"

// ----- Chains ----------------------------------------------------------------

export type ChainId = "testnet" | "ethereum" | "avalanche" | "robinhood"

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
  { id: "testnet", label: "Testnet", iconSrc: "/asset-icons/testnet.png" },
  { id: "ethereum", label: "Ethereum", brand: true, iconSrc: "/asset-icons/eth.png" },
  { id: "avalanche", label: "Avalanche", brand: true, iconSrc: "/asset-icons/avalanche.png" },
  { id: "robinhood", label: "Robinhood", brand: true, iconSrc: "/stock-Icons/robinhood.png" },
]

/**
 * Every market runs on the testnet until mainnet launches, so each one belongs to `testnet` only
 * and the named chains are listed (with zero markets) for what's coming. At mainnet, derive the
 * real chain per market here.
 */
export const MARKET_CHAINS: readonly ChainId[] = ["testnet"]

function isStockSymbol(symbol: string): boolean {
  return Boolean(getRegistryToken(symbol)?.iconPath?.startsWith("/stock-Icons/"))
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

const categoryOptions = (product: "lend" | "multiply"): ReadonlyArray<FilterOption<MarketCategory>> =>
  CATEGORY_CHIPS[product]
    .filter((chip): chip is { id: MarketCategory; label: string } => chip.id !== "all")
    .map((chip) => ({ id: chip.id, label: chip.label }))

export const LEND_MARKET_OPTIONS = categoryOptions("lend")
export const MULTIPLY_MARKET_OPTIONS = categoryOptions("multiply")

export type BorrowMarketId =
  | "uniswap-v2"
  | "uniswap-v3"
  | "curve"
  | "aerodrome-basic"
  | "aerodrome-slipstream"
  | "balancer"
  | "cow-swap"
  | "uniswap-v4"
  | "sushi"
  | "balancer-v2"

export const BORROW_MARKET_OPTIONS: ReadonlyArray<FilterOption<BorrowMarketId>> = [
  { id: "uniswap-v2", label: "Uniswap V2", brand: true, iconSrc: "/asset-icons/uni.png" },
  { id: "uniswap-v3", label: "Uniswap V3", brand: true, iconSrc: "/asset-icons/uni.png" },
  { id: "curve", label: "Curve", brand: true, iconSrc: "/asset-icons/crv.png" },
  { id: "aerodrome-basic", label: "Aerodrome Basic", brand: true, iconSrc: "/asset-icons/aero.png" },
  { id: "aerodrome-slipstream", label: "Aerodrome Slipstream", brand: true, iconSrc: "/asset-icons/aero.png" },
  { id: "balancer", label: "Balancer", brand: true, iconSrc: "/asset-icons/bal.png" },
  { id: "cow-swap", label: "CoW Swap", brand: true, iconSrc: "/asset-icons/cowswap.png", soon: true },
  { id: "uniswap-v4", label: "Uniswap V4", brand: true, iconSrc: "/asset-icons/uni.png", soon: true },
  { id: "sushi", label: "Sushi", brand: true, iconSrc: "/asset-icons/sushiswap.png", soon: true },
  { id: "balancer-v2", label: "Balancer V2", brand: true, iconSrc: "/asset-icons/bal.png", soon: true },
]

/** Borrow spoke id → the DEX market its LP positions come from. */
export function borrowMarketForSpoke(spoke: string): BorrowMarketId | null {
  if (spoke === "uni-v2") return "uniswap-v2"
  if (spoke.startsWith("uni-")) return "uniswap-v3"
  if (spoke.startsWith("curve-")) return "curve"
  if (spoke.startsWith("aero-basic-")) return "aerodrome-basic"
  if (spoke.startsWith("aero-")) return "aerodrome-slipstream"
  if (spoke.startsWith("bal-")) return "balancer"
  return null
}

/**
 * Multiply loop categories, matching the old chip semantics: BTC/ETH/Utility when either leg is
 * in that family, Forex when both legs are stablecoins, Smart for same-family (correlated) loops.
 */
export function loopCategories(collateral: string, borrow: string): MarketCategory[] {
  const a = categorizeMarket(collateral)
  const b = categorizeMarket(borrow)
  const categories = new Set<MarketCategory>()
  if (a === "btc" || b === "btc") categories.add("btc")
  if (a === "eth" || b === "eth") categories.add("eth")
  if (a === "forex" && b === "forex") categories.add("forex")
  if (a === "utility" || b === "utility") categories.add("utility")
  if (a === b && (a === "eth" || a === "forex" || a === "btc")) categories.add("smart")
  return [...categories]
}

// ----- Assets ----------------------------------------------------------------

export type AssetTabId = "all" | "stable" | "eth" | "btc" | "stocks" | "other"

export const ASSET_TABS: ReadonlyArray<{ id: AssetTabId; label: string }> = [
  { id: "all", label: "All" },
  { id: "stable", label: "Stablecoins" },
  { id: "eth", label: "ETH" },
  { id: "btc", label: "BTC" },
  { id: "stocks", label: "Stocks" },
  { id: "other", label: "Other" },
]

export function assetTabFor(symbol: string): Exclude<AssetTabId, "all"> {
  const family = categorizeMarket(symbol)
  if (family === "forex") return "stable"
  if (family === "eth" || family === "btc") return family
  if (isStockSymbol(symbol.trim().toUpperCase())) return "stocks"
  return "other"
}

export type AssetOption = { symbol: string; name: string; tab: Exclude<AssetTabId, "all"> }

/** One option per symbol (case-insensitive), sorted by name then symbol. */
export function buildAssetOptions(entries: ReadonlyArray<{ symbol: string; name?: string }>): AssetOption[] {
  const bySymbol = new Map<string, AssetOption>()
  for (const entry of entries) {
    const key = entry.symbol.trim().toUpperCase()
    if (!key || bySymbol.has(key)) continue
    // A "name" that is just the symbol again (Multiply rows) is no name at all.
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

export function multiplyFilterItem(collateral: string, borrow: string): FilterableItem {
  return {
    chains: MARKET_CHAINS,
    hub: hubForSymbols([collateral, borrow]),
    markets: loopCategories(collateral, borrow),
    assets: [collateral.toUpperCase(), borrow.toUpperCase()],
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
  visuals: ReadonlyArray<{ symbol: string }>
  constituents?: ReadonlyArray<{ symbol: string }>
}): FilterableItem {
  const symbols = borrowPoolSymbols(pool)
  const market = borrowMarketForSpoke(pool.spoke)
  return {
    chains: MARKET_CHAINS,
    hub: hubForSymbols(symbols),
    markets: market ? [market] : [],
    assets: symbols.map((symbol) => symbol.toUpperCase()),
  }
}
