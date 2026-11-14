// Row shapes and display helpers of the Borrow markets lists. Rows are built from the markets
// services/convex reports (see borrow-system/snapshot-state.ts); there is no static catalog.
import { getTokenIconMeta } from "@/app/lib/token-icons"
import { getActiveCurrency, withCurrencySymbol } from "@/app/lib/currency/active-rate"
import { healthFactorBand } from "@/app/lib/health/health-factor-bands"
import { lpTokenPriceUsd, type WeightedConstituent } from "@/app/lib/prices/lp-token-price"
import { canonicalPriceUsd } from "@/app/lib/prices/canonical"

/** A DEX (AMM protocol) whose LP positions a CDP Spoke accepts, keyed by its listing slug. */
export type BorrowDexId = string

/** A CDP Spoke, keyed by the id services/convex reports for it. */
export type BorrowSpokeId = string

export type BorrowAssetVisual = {
  symbol: string
  shortLabel: string
  bgClass: string
  textClass: string
  iconUrl?: string
}

export type BorrowDex = {
  id: BorrowDexId
  label: string
  tvlUsd: number
  dotClass: string
  pillBgClass: string
  pillTextClass: string
  iconUrl?: string
}

export type BorrowSpoke = {
  id: BorrowSpokeId
  dex: BorrowDexId
  label: string
  description: string
  eMode: boolean
  borrowableTokens: BorrowAssetVisual[]
  maxLtv: number
  aprApprox: number
  riskPremiumBps: number
  liquidityUsd: number
  dotClass: string
  pillBgClass: string
  pillTextClass: string
  liquidationUsdApprox: number
}

export type DexChip = {
  id: string
  label: string
  starred?: boolean
}

export type BorrowPoolEvent = {
  label: string
  tone?: "info" | "positive" | "warning" | "danger"
}

export type BorrowPoolRow = {
  id: string
  name: string
  venue: string
  feeTier: string
  tvlUsd: number
  change24hPct?: number
  spoke: BorrowSpokeId
  /** Display label of the row's Spoke and of the DEX its LP positions come from. */
  spokeLabel: string
  dexId: BorrowDexId
  dexLabel: string
  /** Chain label of the market ("Ethereum", "Base", "Local"). */
  chain?: string
  ltv: number
  dexes: DexChip[]
  borrowableTokens: BorrowAssetVisual[]
  aprMin: number
  aprMax: number
  availableUsd: number
  capacityFilledPct?: number
  riskPremiumBps: number
  visuals: [BorrowAssetVisual, BorrowAssetVisual]
  /**
   * Full pool composition with NORMALIZED weights (fractions summing to 1), supporting 2/3/4+
   * tokens. This is what LP-collateral valuation reads: LPPriceUSD = Σ(weightᵢ × priceᵢ). The
   * two-leg `visuals` above remain for display only. Symbols are display/visual symbols; the
   * pricing layer normalizes them (ETH→WETH, upper-cases) before resolving canonical prices.
   */
  constituents: WeightedConstituent[]
  collateralExampleUsd: number
  trendUp: boolean
  trendValues?: number[]
  events?: BorrowPoolEvent[]
}

/**
 * USD price of a single LP token = Σ(weightᵢ × canonicalPriceᵢ) over the pool's constituents
 * (the one Avana LP-collateral model — see lp-token-price.ts). This is the SINGLE source of
 * truth for the display layer; protocol values come from the market's LPOracle price.
 *
 * Returns null when a constituent has no price: the caller shows its unavailable state.
 */
export function poolLpTokenPriceUsd(pool: Pick<BorrowPoolRow, "constituents">): number | null {
  const result = lpTokenPriceUsd(pool.constituents, canonicalPriceUsd)
  return result.ok ? result.priceUsd : null
}

// ----- Discovery label helpers ----------------------------------------------

/**
 * Single source of truth for rendering a pool/market LTV (collateral factor) as
 * a percent string. Every borrow discovery surface (explore, list desktop +
 * mobile, search) routes through this so the same collateral factor never reads
 * as 79.5% in one place and 80% in another. Keeps one decimal of precision — the
 * granularity the collateral factor itself carries — and trims a trailing ".0"
 * so whole-number factors stay clean (65% rather than 65.0%).
 */
export function formatLtvPct(ltv: number): string {
  const rounded = Math.round(ltv * 10) / 10
  return `${Number.isInteger(rounded) ? rounded : rounded.toFixed(1)}%`
}

/**
 * Canonicalize a token symbol for display. Markets can mix native
 * "ETH" and wrapped "WETH" labels for the same underlying collateral asset;
 * collapse the bare native symbol to WETH so an identical asset never reads as
 * two different tokens. ETH-suffixed LSTs (stETH, wstETH, weETH, rETH, cbETH)
 * are distinct assets and are left untouched.
 */
export function normalizeBorrowTokenSymbol(symbol: string): string {
  return symbol === "ETH" ? "WETH" : symbol
}

/**
 * Canonical pair label for a borrow pool row, shared by every discovery surface
 * so the same pool reads identically everywhere. Uses the pool's display name
 * (which keeps multi-token compositions like "USDC / WBTC / ETH" distinct from a
 * plain "WBTC / ETH" pool) and applies token-symbol normalization (ETH -> WETH).
 */
export function formatBorrowPairLabel(pool: Pick<BorrowPoolRow, "name">): string {
  return pool.name
    .split(" / ")
    .map((part) => normalizeBorrowTokenSymbol(part.trim()))
    .join(" / ")
}

export type BorrowableAssetCategory = "stable" | "eth" | "btc" | "crypto"

export type BorrowableAsset = {
  id: string
  symbol: string
  name: string
  subtitle: string
  borrowApr: number
  totalBorrowedUsd: number
  utilization: number
  availableUsd: number
  walletBalanceLabel: string
  hasWalletBalance: boolean
  visual: BorrowAssetVisual
  trendUp: boolean
  trendValues?: number[]
  category: BorrowableAssetCategory
}

export const BORROWABLE_CATEGORIES: { id: BorrowableAssetCategory; label: string; dotClass: string }[] = [
  { id: "stable", label: "Stablecoins", dotClass: "bg-emerald-500" },
  { id: "eth", label: "ETH", dotClass: "bg-indigo-500" },
  { id: "btc", label: "BTC", dotClass: "bg-amber-500" },
  { id: "crypto", label: "Crypto", dotClass: "bg-blue-500" },
]

export type PendingMarketRow = {
  id: string
  spoke: BorrowSpokeId
  label: string
  subLabel: string
}

// ----- Display helpers ------------------------------------------------------

export function aprRangeLabel(pool: BorrowPoolRow): string {
  if (!Number.isFinite(pool.aprMin) || !Number.isFinite(pool.aprMax)) return "—"
  if (pool.aprMin === pool.aprMax) {
    return `${pool.aprMin.toFixed(1)}%`
  }
  return `${pool.aprMin.toFixed(1)}–${pool.aprMax.toFixed(1)}%`
}

export function formatRiskPremium(bps: number): string {
  if (!Number.isFinite(bps)) return "—"
  const value = bps / 100
  return `+${value.toFixed(2)}%`
}

export function formatCompactUsd(usdValue: number): string {
  if (!Number.isFinite(usdValue)) return "—"
  const { rate } = getActiveCurrency()
  const value = usdValue * rate
  // Compact on magnitude; the sign is reattached (outside the symbol) by withCurrencySymbol.
  const abs = Math.abs(value)
  if (abs >= 1_000_000_000) return withCurrencySymbol(value, `${(abs / 1_000_000_000).toFixed(1)}B`)
  if (abs >= 1_000_000) return withCurrencySymbol(value, `${(abs / 1_000_000).toFixed(1)}M`)
  if (abs >= 1_000) return withCurrencySymbol(value, `${(abs / 1_000).toFixed(1)}K`)
  if (abs === 0) return withCurrencySymbol(0, "0")
  return withCurrencySymbol(value, abs.toLocaleString("en-US", { maximumFractionDigits: abs >= 100 ? 0 : 2 }))
}

export function formatUsdExact(usdValue: number): string {
  if (!Number.isFinite(usdValue)) return "—"
  const { rate, zeroDecimal } = getActiveCurrency()
  const value = usdValue * rate
  const abs = Math.abs(value)
  const maximumFractionDigits = zeroDecimal ? 0 : abs >= 100 ? 0 : 2
  return withCurrencySymbol(value, abs.toLocaleString("en-US", { maximumFractionDigits }))
}

// ----- Filtering / grouping / sorting --------------------------------------

type PoolFilterOptions = {
  text?: string
  dexes?: Set<BorrowDexId>
  spokes?: Set<BorrowSpokeId>
}

export function filterPools(rows: BorrowPoolRow[], { text = "", dexes, spokes }: PoolFilterOptions = {}): BorrowPoolRow[] {
  const needle = text.trim().toLowerCase()
  const activeDexes = dexes && dexes.size > 0 ? dexes : null
  const activeSpokes = spokes && spokes.size > 0 ? spokes : null
  return rows.filter((row) => {
    if (activeDexes && !activeDexes.has(row.dexId)) return false
    if (activeSpokes && !activeSpokes.has(row.spoke)) return false
    if (!needle) return true
    return (
      row.name.toLowerCase().includes(needle) ||
      row.venue.toLowerCase().includes(needle) ||
      row.dexes.some((dex) => dex.label.toLowerCase().includes(needle))
    )
  })
}

export type DexGroup = {
  dex: BorrowDex
  spokes: Array<{ spoke: BorrowSpoke; rows: BorrowPoolRow[] }>
}

const NEUTRAL_PILL = {
  dotClass: "bg-muted-foreground",
  pillBgClass: "bg-muted",
  pillTextClass: "text-foreground",
}

/** The DEX descriptor of a row, from what services/convex reports for its market. */
export function dexForRow(row: Pick<BorrowPoolRow, "dexId" | "dexLabel">): BorrowDex {
  return { id: row.dexId, label: row.dexLabel, tvlUsd: 0, ...NEUTRAL_PILL }
}

/** The Spoke descriptor of a row. Only the fields the list renders are known; the rest stay neutral. */
export function spokeForRow(row: Pick<BorrowPoolRow, "spoke" | "spokeLabel" | "dexId" | "ltv">): BorrowSpoke {
  return {
    id: row.spoke,
    dex: row.dexId,
    label: row.spokeLabel,
    description: "",
    eMode: false,
    borrowableTokens: [],
    maxLtv: row.ltv,
    aprApprox: 0,
    riskPremiumBps: 0,
    liquidityUsd: 0,
    liquidationUsdApprox: 0,
    ...NEUTRAL_PILL,
  }
}

/** Group rows by DEX, then Spoke, in the order they first appear. */
export function groupByDex(rows: BorrowPoolRow[]): DexGroup[] {
  const groups = new Map<string, DexGroup>()
  for (const row of rows) {
    let group = groups.get(row.dexId)
    if (!group) {
      group = { dex: dexForRow(row), spokes: [] }
      groups.set(row.dexId, group)
    }
    let entry = group.spokes.find((candidate) => candidate.spoke.id === row.spoke)
    if (!entry) {
      entry = { spoke: spokeForRow(row), rows: [] }
      group.spokes.push(entry)
    }
    entry.rows.push(row)
  }
  return [...groups.values()]
}

/**
 * Sort pools into the exact order `groupByDex` renders them (DEX, then spoke; stable within a
 * spoke). Progressive reveal slices BEFORE grouping, so an unordered slice would drop newly
 * revealed rows into groups above the viewport and make the page jump.
 */
export function orderPoolsForDexGroups(rows: readonly BorrowPoolRow[]): BorrowPoolRow[] {
  return groupByDex([...rows]).flatMap((group) => group.spokes.flatMap((entry) => entry.rows))
}

export function aprToneClass(apr: number): string {
  if (apr < 4) return "text-success"
  if (apr < 5.5) return "text-amber-700 dark:text-amber-300"
  return "text-rose-700 dark:text-rose-300"
}

export function utilizationToneClass(utilization: number): string {
  if (utilization < 65) return "text-success"
  if (utilization < 85) return "text-amber-700 dark:text-amber-300"
  return "text-rose-700 dark:text-rose-300"
}

export function healthFactorToneClass(hf: number | null): string {
  // ∞ (no debt) stays muted here — per-row tables treat it as "not applicable"
  // rather than a green badge. Finite values defer to the shared band scale.
  if (hf === null || !Number.isFinite(hf)) return "text-muted-foreground"
  return healthFactorBand(hf).textClass
}

export function homeVisualToBorrowVisual(visual: {
  symbol: string
  shortLabel: string
  bgClassName: string
  textClassName: string
}): BorrowAssetVisual {
  return {
    symbol: visual.symbol,
    shortLabel: visual.shortLabel,
    bgClass: visual.bgClassName,
    textClass: visual.textClassName,
    iconUrl: getTokenIconMeta(visual.symbol).iconUrl,
  }
}
