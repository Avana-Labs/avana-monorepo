import { getTokenIconMeta } from "@/app/lib/token-icons"
import { getActiveCurrency, withCurrencySymbol } from "@/app/lib/currency/active-rate"
import { healthFactorBand } from "@/app/lib/health/health-factor-bands"
import { lpTokenPriceUsd, normalizeWeights, type WeightedConstituent } from "@/app/lib/prices/lp-token-price"
import { canonicalPriceUsd } from "@/app/lib/prices/canonical"

export type BorrowDexId = "uniswap" | "curve" | "balancer" | "aerodrome"

export type BorrowSpokeId =
  | "uni-v2"
  | "uni-v3-stable"
  | "uni-v3-bluechip"
  | "uni-v3-gov"
  | "curve-stable"
  | "curve-correlated"
  | "curve-crypto"
  | "bal-stable"
  | "bal-correlated"
  | "bal-weighted"
  | "bal-boosted"
  | "bal-reclamm"
  | "aero-basic-stable"
  | "aero-basic-volatile"
  | "aero-slipstream-bluechip"
  | "aero-concentrated-stocks"
  | "uni-robinhood-stocks"

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
 * truth shared by the client market snapshot (borrow-system/mock.ts) and the Convex seed
 * (convex-seed/build-seed.ts), so the server values 18-decimal LP-token collateral amounts with
 * the exact price the client derived them from; a divergence would make server solvency reject
 * borrows the client preview allowed.
 *
 * Fallback: when a constituent leg has no canonical price (exotic Aerodrome/boosted tokens the
 * snapshot doesn't cover), the weighted sum is unavailable and we fall back to the example-
 * position heuristic so the sandbox pool still functions. This is NOT a competing model — it is
 * only reached when Σ(weight×price) genuinely can't be computed, and disappears once the oracle
 * covers those legs.
 */
export function poolLpTokenPriceUsd(pool: Pick<BorrowPoolRow, "constituents" | "collateralExampleUsd">): number {
  const result = lpTokenPriceUsd(pool.constituents, canonicalPriceUsd)
  if (result.ok) return result.priceUsd
  return Math.max(1, pool.collateralExampleUsd / 2.5)
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
 * Canonicalize a token symbol for display. The borrow catalog mixes native
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

// ----- Token visual catalog -------------------------------------------------

const VISUALS = {
  USDC: {
    symbol: "USDC",
    shortLabel: "U",
    bgClass: "bg-sky-100",
    textClass: "text-sky-700",
    iconUrl: getTokenIconMeta("USDC").iconUrl,
  },
  USDT: {
    symbol: "USDT",
    shortLabel: "T",
    bgClass: "bg-emerald-100",
    textClass: "text-emerald-700",
    iconUrl: getTokenIconMeta("USDT").iconUrl,
  },
  DAI: {
    symbol: "DAI",
    shortLabel: "D",
    bgClass: "bg-orange-100",
    textClass: "text-orange-700",
    iconUrl: getTokenIconMeta("DAI").iconUrl,
  },
  GHO: {
    symbol: "GHO",
    shortLabel: "G",
    bgClass: "bg-violet-100",
    textClass: "text-violet-700",
    iconUrl: getTokenIconMeta("GHO").iconUrl,
  },
  crvUSD: {
    symbol: "crvUSD",
    shortLabel: "cU",
    bgClass: "bg-rose-100",
    textClass: "text-rose-700",
    iconUrl: getTokenIconMeta("crvUSD").iconUrl,
  },
  USDe: {
    symbol: "USDe",
    shortLabel: "Ue",
    bgClass: "bg-muted",
    textClass: "text-foreground",
    iconUrl: getTokenIconMeta("USDe").iconUrl,
  },
  FRAX: {
    symbol: "FRAX",
    shortLabel: "F",
    bgClass: "bg-zinc-100",
    textClass: "text-zinc-700",
    iconUrl: getTokenIconMeta("FRAX").iconUrl,
  },
  EURC: {
    symbol: "EURC",
    shortLabel: "€",
    bgClass: "bg-blue-100",
    textClass: "text-blue-700",
    iconUrl: getTokenIconMeta("EURC").iconUrl,
  },
  sDAI: {
    symbol: "sDAI",
    shortLabel: "sD",
    bgClass: "bg-orange-100",
    textClass: "text-orange-600",
    iconUrl: getTokenIconMeta("sDAI").iconUrl,
  },
  "USD+": {
    symbol: "USD+",
    shortLabel: "+",
    bgClass: "bg-teal-100",
    textClass: "text-teal-700",
    iconUrl: getTokenIconMeta("USD+").iconUrl,
  },
  ETH: {
    symbol: "ETH",
    shortLabel: "E",
    bgClass: "bg-indigo-100",
    textClass: "text-indigo-700",
    iconUrl: getTokenIconMeta("ETH").iconUrl,
  },
  WETH: {
    symbol: "WETH",
    shortLabel: "W",
    bgClass: "bg-indigo-100",
    textClass: "text-indigo-700",
    iconUrl: getTokenIconMeta("WETH").iconUrl,
  },
  WBTC: {
    symbol: "WBTC",
    shortLabel: "B",
    bgClass: "bg-amber-100",
    textClass: "text-amber-700",
    iconUrl: getTokenIconMeta("WBTC").iconUrl,
  },
  cbBTC: {
    symbol: "cbBTC",
    shortLabel: "cB",
    bgClass: "bg-blue-100",
    textClass: "text-blue-700",
    iconUrl: getTokenIconMeta("cbBTC").iconUrl,
  },
  stETH: {
    symbol: "stETH",
    shortLabel: "st",
    bgClass: "bg-sky-100",
    textClass: "text-sky-600",
    iconUrl: getTokenIconMeta("stETH").iconUrl,
  },
  wstETH: {
    symbol: "wstETH",
    shortLabel: "ws",
    bgClass: "bg-sky-100",
    textClass: "text-sky-600",
    iconUrl: getTokenIconMeta("wstETH").iconUrl,
  },
  rETH: {
    symbol: "rETH",
    shortLabel: "r",
    bgClass: "bg-orange-100",
    textClass: "text-orange-600",
    iconUrl: getTokenIconMeta("rETH").iconUrl,
  },
  cbETH: {
    symbol: "cbETH",
    shortLabel: "cE",
    bgClass: "bg-blue-100",
    textClass: "text-blue-600",
    iconUrl: getTokenIconMeta("cbETH").iconUrl,
  },
  weETH: {
    symbol: "weETH",
    shortLabel: "we",
    bgClass: "bg-indigo-100",
    textClass: "text-indigo-600",
    iconUrl: getTokenIconMeta("weETH").iconUrl,
  },
  AAVE: {
    symbol: "AAVE",
    shortLabel: "A",
    bgClass: "bg-violet-100",
    textClass: "text-violet-700",
    iconUrl: getTokenIconMeta("AAVE").iconUrl,
  },
  UNI: {
    symbol: "UNI",
    shortLabel: "U",
    bgClass: "bg-pink-100",
    textClass: "text-pink-700",
    iconUrl: getTokenIconMeta("UNI").iconUrl,
  },
  CRV: {
    symbol: "CRV",
    shortLabel: "C",
    bgClass: "bg-rose-100",
    textClass: "text-rose-700",
    iconUrl: getTokenIconMeta("CRV").iconUrl,
  },
  LDO: {
    symbol: "LDO",
    shortLabel: "L",
    bgClass: "bg-sky-100",
    textClass: "text-sky-700",
    iconUrl: getTokenIconMeta("LDO").iconUrl,
  },
  BAL: {
    symbol: "BAL",
    shortLabel: "B",
    bgClass: "bg-muted",
    textClass: "text-foreground",
    iconUrl: getTokenIconMeta("BAL").iconUrl,
  },
  GNO: {
    symbol: "GNO",
    shortLabel: "G",
    bgClass: "bg-emerald-100",
    textClass: "text-emerald-700",
    iconUrl: getTokenIconMeta("GNO").iconUrl,
  },
  AURA: {
    symbol: "AURA",
    shortLabel: "Au",
    bgClass: "bg-amber-100",
    textClass: "text-amber-700",
    iconUrl: getTokenIconMeta("AURA").iconUrl,
  },
  AERO: {
    symbol: "AERO",
    shortLabel: "Ae",
    bgClass: "bg-blue-100",
    textClass: "text-blue-700",
    iconUrl: getTokenIconMeta("AERO").iconUrl,
  },
  DEGEN: {
    symbol: "DEGEN",
    shortLabel: "Dg",
    bgClass: "bg-violet-100",
    textClass: "text-violet-700",
    iconUrl: getTokenIconMeta("DEGEN").iconUrl,
  },
  BRETT: {
    symbol: "BRETT",
    shortLabel: "Br",
    bgClass: "bg-blue-100",
    textClass: "text-blue-600",
    iconUrl: getTokenIconMeta("BRETT").iconUrl,
  },
  WELL: {
    symbol: "WELL",
    shortLabel: "W",
    bgClass: "bg-teal-100",
    textClass: "text-teal-700",
    iconUrl: getTokenIconMeta("WELL").iconUrl,
  },
  MOG: {
    symbol: "MOG",
    shortLabel: "M",
    bgClass: "bg-yellow-100",
    textClass: "text-yellow-700",
  },
  CRV3: {
    symbol: "3CRV",
    shortLabel: "3",
    bgClass: "bg-orange-100",
    textClass: "text-orange-700",
    iconUrl: getTokenIconMeta("3CRV").iconUrl,
  },
  ARB: {
    symbol: "ARB",
    shortLabel: "A",
    bgClass: "bg-indigo-100",
    textClass: "text-indigo-600",
    iconUrl: getTokenIconMeta("ARB").iconUrl,
  },
  OP: {
    symbol: "OP",
    shortLabel: "O",
    bgClass: "bg-rose-100",
    textClass: "text-rose-600",
    iconUrl: getTokenIconMeta("OP").iconUrl,
  },
  // ----- Tokenized stocks + USDG -----
  // Aerodrome "…c" collateral variants + Uniswap plain tickers. Icons/prices resolve through the
  // token registry (app/lib/tokens/registry.ts) via getTokenIconMeta; USDG uses its asset-icons file.
  USDG: {
    symbol: "USDG",
    shortLabel: "G$",
    bgClass: "bg-teal-100",
    textClass: "text-teal-700",
    iconUrl: getTokenIconMeta("USDG").iconUrl,
  },
  NVDA: {
    symbol: "NVDA",
    shortLabel: "Nv",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("NVDA").iconUrl,
  },
  NVDAc: {
    symbol: "NVDAc",
    shortLabel: "Nv",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("NVDAc").iconUrl,
  },
  AAPL: {
    symbol: "AAPL",
    shortLabel: "Ap",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("AAPL").iconUrl,
  },
  AAPLc: {
    symbol: "AAPLc",
    shortLabel: "Ap",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("AAPLc").iconUrl,
  },
  GOOGL: {
    symbol: "GOOGL",
    shortLabel: "Go",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("GOOGL").iconUrl,
  },
  GOOGLc: {
    symbol: "GOOGLc",
    shortLabel: "Go",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("GOOGLc").iconUrl,
  },
  META: {
    symbol: "META",
    shortLabel: "Me",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("META").iconUrl,
  },
  METAc: {
    symbol: "METAc",
    shortLabel: "Me",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("METAc").iconUrl,
  },
  AMZNc: {
    symbol: "AMZNc",
    shortLabel: "Az",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("AMZNc").iconUrl,
  },
  MSFTc: {
    symbol: "MSFTc",
    shortLabel: "Ms",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("MSFTc").iconUrl,
  },
  TSLA: {
    symbol: "TSLA",
    shortLabel: "Ts",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("TSLA").iconUrl,
  },
  TSLAc: {
    symbol: "TSLAc",
    shortLabel: "Ts",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("TSLAc").iconUrl,
  },
  SPCX: {
    symbol: "SPCX",
    shortLabel: "Sx",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("SPCX").iconUrl,
  },
  SPCXc: {
    symbol: "SPCXc",
    shortLabel: "Sx",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("SPCXc").iconUrl,
  },
  AMC: {
    symbol: "AMC",
    shortLabel: "Am",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("AMC").iconUrl,
  },
  MU: {
    symbol: "MU",
    shortLabel: "Mu",
    bgClass: "bg-slate-100",
    textClass: "text-slate-700",
    iconUrl: getTokenIconMeta("MU").iconUrl,
  },
} satisfies Record<string, BorrowAssetVisual>

function v(symbol: keyof typeof VISUALS): BorrowAssetVisual {
  return VISUALS[symbol]
}

// ----- DEX + Spoke taxonomy -------------------------------------------------

export const BORROW_DEXES: BorrowDex[] = [
  {
    id: "uniswap",
    label: "Uniswap",
    tvlUsd: 5_680_000_000,
    dotClass: "bg-pink-500",
    pillBgClass: "bg-pink-50",
    pillTextClass: "text-pink-700",
  },
  {
    id: "curve",
    label: "Curve",
    tvlUsd: 1_830_000_000,
    dotClass: "bg-rose-500",
    pillBgClass: "bg-rose-50",
    pillTextClass: "text-rose-700",
  },
  {
    id: "balancer",
    label: "Balancer",
    tvlUsd: 158_180_000,
    dotClass: "bg-slate-700",
    pillBgClass: "bg-muted",
    pillTextClass: "text-foreground",
  },
  {
    id: "aerodrome",
    label: "Aerodrome",
    tvlUsd: 356_440_000,
    dotClass: "bg-blue-500",
    pillBgClass: "bg-blue-50",
    pillTextClass: "text-blue-700",
  },
]

const DEX_BY_ID = {} as Record<BorrowDexId, BorrowDex>
for (const dex of BORROW_DEXES) {
  DEX_BY_ID[dex.id] = dex
}

export const BORROW_SPOKES: BorrowSpoke[] = [
  // -------- Uniswap --------
  {
    id: "uni-v2",
    dex: "uniswap",
    label: "Uniswap v2 LPs",
    description: "Constant-product LP tokens",
    eMode: false,
    borrowableTokens: [v("USDC"), v("USDT"), v("DAI"), v("WETH"), v("WBTC")],
    maxLtv: 65,
    aprApprox: 4.8,
    riskPremiumBps: 80,
    liquidityUsd: 820_000_000,
    dotClass: "bg-pink-500",
    pillBgClass: "bg-pink-50",
    pillTextClass: "text-pink-700",
    liquidationUsdApprox: 1_800,
  },
  {
    id: "uni-v3-stable",
    dex: "uniswap",
    label: "Uniswap v3 Stable LPs",
    description: "Concentrated-liquidity LP positions",
    eMode: true,
    borrowableTokens: [v("USDC"), v("USDT"), v("DAI"), v("crvUSD"), v("GHO")],
    maxLtv: 92,
    aprApprox: 3.2,
    riskPremiumBps: 25,
    liquidityUsd: 1_250_000_000,
    dotClass: "bg-emerald-500",
    pillBgClass: "bg-emerald-50",
    pillTextClass: "text-emerald-700",
    liquidationUsdApprox: 2_300,
  },
  {
    id: "uni-v3-bluechip",
    dex: "uniswap",
    label: "Uniswap v3 Blue-Chip LPs",
    description: "Concentrated-liquidity LP positions",
    eMode: false,
    borrowableTokens: [v("USDC"), v("USDT"), v("DAI"), v("WETH"), v("WBTC")],
    maxLtv: 78,
    aprApprox: 5.8,
    riskPremiumBps: 70,
    liquidityUsd: 2_400_000_000,
    dotClass: "bg-blue-500",
    pillBgClass: "bg-blue-50",
    pillTextClass: "text-blue-700",
    liquidationUsdApprox: 3_400,
  },
  {
    id: "uni-v3-gov",
    dex: "uniswap",
    label: "Uniswap v3 Governance & DAO LPs",
    description: "Concentrated-liquidity LP positions",
    eMode: false,
    borrowableTokens: [v("USDC"), v("USDT"), v("DAI"), v("WETH")],
    maxLtv: 55,
    aprApprox: 7.8,
    riskPremiumBps: 180,
    liquidityUsd: 1_210_000_000,
    dotClass: "bg-amber-500",
    pillBgClass: "bg-amber-50",
    pillTextClass: "text-amber-700",
    liquidationUsdApprox: 1_200,
  },
  // Tokenized stocks (Uniswap Robinhood, USDG-quoted). Grouped with the other
  // Uniswap spokes so it surfaces in the catalog with them, not buried on the last page.
  {
    id: "uni-robinhood-stocks",
    dex: "uniswap",
    label: "Uniswap Robinhood Stocks",
    description: "Tokenized-equity concentrated LP positions",
    eMode: false,
    borrowableTokens: [v("USDG"), v("GHO"), v("USDC"), v("USDT")],
    maxLtv: 55,
    aprApprox: 12,
    riskPremiumBps: 180,
    liquidityUsd: 30_000_000,
    dotClass: "bg-pink-500",
    pillBgClass: "bg-pink-50",
    pillTextClass: "text-pink-700",
    liquidationUsdApprox: 1_100,
  },

  // -------- Curve --------
  {
    id: "curve-stable",
    dex: "curve",
    label: "Curve Stable LPs",
    description: "StableSwap LP tokens",
    eMode: true,
    borrowableTokens: [v("USDC"), v("USDT"), v("DAI"), v("crvUSD"), v("GHO")],
    maxLtv: 92,
    aprApprox: 2.9,
    riskPremiumBps: 20,
    liquidityUsd: 720_000_000,
    dotClass: "bg-emerald-500",
    pillBgClass: "bg-emerald-50",
    pillTextClass: "text-emerald-700",
    liquidationUsdApprox: 2_100,
  },
  {
    id: "curve-correlated",
    dex: "curve",
    label: "Curve Correlated LPs",
    description: "StableSwap LP tokens",
    eMode: true,
    borrowableTokens: [v("ETH"), v("stETH"), v("wstETH"), v("rETH")],
    maxLtv: 90,
    aprApprox: 3.4,
    riskPremiumBps: 40,
    liquidityUsd: 680_000_000,
    dotClass: "bg-sky-500",
    pillBgClass: "bg-sky-50",
    pillTextClass: "text-sky-700",
    liquidationUsdApprox: 2_900,
  },
  {
    id: "curve-crypto",
    dex: "curve",
    label: "Curve Crypto LPs",
    description: "CryptoSwap LP tokens",
    eMode: false,
    borrowableTokens: [v("USDC"), v("USDT"), v("DAI"), v("WETH"), v("WBTC")],
    maxLtv: 70,
    aprApprox: 6.1,
    riskPremiumBps: 110,
    liquidityUsd: 430_000_000,
    dotClass: "bg-orange-500",
    pillBgClass: "bg-orange-50",
    pillTextClass: "text-orange-700",
    liquidationUsdApprox: 2_400,
  },

  // -------- Balancer --------
  {
    id: "bal-stable",
    dex: "balancer",
    label: "Balancer Stable LPs",
    description: "Stable / Composable Stable BPT",
    eMode: true,
    borrowableTokens: [v("USDC"), v("DAI"), v("USDT"), v("EURC"), v("GHO")],
    maxLtv: 90,
    aprApprox: 3.4,
    riskPremiumBps: 25,
    liquidityUsd: 52_000_000,
    dotClass: "bg-emerald-500",
    pillBgClass: "bg-emerald-50",
    pillTextClass: "text-emerald-700",
    liquidationUsdApprox: 2_050,
  },
  {
    id: "bal-correlated",
    dex: "balancer",
    label: "Balancer Correlated LPs",
    description: "Stable / Composable Stable BPT",
    eMode: true,
    borrowableTokens: [v("WETH"), v("wstETH"), v("rETH"), v("cbETH")],
    maxLtv: 88,
    aprApprox: 3.0,
    riskPremiumBps: 45,
    liquidityUsd: 38_000_000,
    dotClass: "bg-sky-500",
    pillBgClass: "bg-sky-50",
    pillTextClass: "text-sky-700",
    liquidationUsdApprox: 2_700,
  },
  {
    id: "bal-weighted",
    dex: "balancer",
    label: "Balancer Weighted LPs",
    description: "Weighted BPT",
    eMode: false,
    borrowableTokens: [v("USDC"), v("USDT"), v("DAI"), v("WETH")],
    maxLtv: 60,
    aprApprox: 6.8,
    riskPremiumBps: 140,
    liquidityUsd: 24_000_000,
    dotClass: "bg-amber-500",
    pillBgClass: "bg-amber-50",
    pillTextClass: "text-amber-700",
    liquidationUsdApprox: 1_350,
  },
  {
    id: "bal-boosted",
    dex: "balancer",
    label: "Balancer Boosted LPs",
    description: "Boosted BPT",
    eMode: false,
    borrowableTokens: [v("USDC"), v("USDT"), v("DAI"), v("GHO")],
    maxLtv: 85,
    aprApprox: 4.5,
    riskPremiumBps: 55,
    liquidityUsd: 26_000_000,
    dotClass: "bg-teal-500",
    pillBgClass: "bg-teal-50",
    pillTextClass: "text-teal-700",
    liquidationUsdApprox: 2_200,
  },
  {
    id: "bal-reclamm",
    dex: "balancer",
    label: "Balancer reCLAMM LPs",
    description: "reCLAMM BPT",
    eMode: false,
    borrowableTokens: [v("USDC"), v("USDT"), v("DAI"), v("WETH")],
    maxLtv: 72,
    aprApprox: 5.4,
    riskPremiumBps: 85,
    liquidityUsd: 18_000_000,
    dotClass: "bg-indigo-500",
    pillBgClass: "bg-indigo-50",
    pillTextClass: "text-indigo-700",
    liquidationUsdApprox: 1_900,
  },

  // -------- Aerodrome --------
  {
    id: "aero-basic-stable",
    dex: "aerodrome",
    label: "Aerodrome Basic Stable LPs",
    description: "Stable LP tokens",
    eMode: true,
    borrowableTokens: [v("USDC"), v("DAI"), v("EURC")],
    maxLtv: 88,
    aprApprox: 4.2,
    riskPremiumBps: 30,
    liquidityUsd: 86_000_000,
    dotClass: "bg-emerald-500",
    pillBgClass: "bg-emerald-50",
    pillTextClass: "text-emerald-700",
    liquidationUsdApprox: 2_050,
  },
  {
    id: "aero-basic-volatile",
    dex: "aerodrome",
    label: "Aerodrome Basic Volatile LPs",
    description: "Constant-product LP tokens",
    eMode: false,
    borrowableTokens: [v("USDC"), v("DAI"), v("WETH")],
    maxLtv: 50,
    aprApprox: 12.5,
    riskPremiumBps: 240,
    liquidityUsd: 64_000_000,
    dotClass: "bg-rose-500",
    pillBgClass: "bg-rose-50",
    pillTextClass: "text-rose-700",
    liquidationUsdApprox: 950,
  },
  {
    id: "aero-slipstream-bluechip",
    dex: "aerodrome",
    label: "Aerodrome Slipstream Blue-Chip LPs",
    description: "Concentrated-liquidity LP positions",
    eMode: false,
    borrowableTokens: [v("USDC"), v("DAI"), v("WETH"), v("cbBTC")],
    maxLtv: 76,
    aprApprox: 6.2,
    riskPremiumBps: 80,
    liquidityUsd: 112_000_000,
    dotClass: "bg-blue-500",
    pillBgClass: "bg-blue-50",
    pillTextClass: "text-blue-700",
    liquidationUsdApprox: 2_500,
  },

  // -------- Tokenized stocks --------
  {
    id: "aero-concentrated-stocks",
    dex: "aerodrome",
    label: "Aerodrome Concentrated 10",
    description: "Tokenized-equity concentrated LP positions",
    eMode: false,
    borrowableTokens: [v("USDC"), v("GHO"), v("USDT")],
    maxLtv: 55,
    aprApprox: 40,
    riskPremiumBps: 180,
    // Real Aerodrome stock pools total ~$10M TVL (USDC/NVDAc $2.29M … USDC/TSLAc $0.70M).
    liquidityUsd: 10_000_000,
    dotClass: "bg-blue-500",
    pillBgClass: "bg-blue-50",
    pillTextClass: "text-blue-700",
    liquidationUsdApprox: 900,
  },
]

const SPOKE_BY_ID = {} as Record<BorrowSpokeId, BorrowSpoke>
for (const spoke of BORROW_SPOKES) {
  SPOKE_BY_ID[spoke.id] = spoke
}

// ----- Pool catalog ---------------------------------------------------------

type VisualSymbol = keyof typeof VISUALS

type PoolSeed = {
  pair: [VisualSymbol, VisualSymbol]
  name?: string
  trendUp?: boolean
  feeTier?: string
  /**
   * Explicit pool composition as raw proportional weights (normalized at build time). Omit for a
   * plain equal-weight 2-token pool over `pair`. Declare it for 3+/weighted pools whose real
   * composition the two-leg `pair` can't express — e.g. equal-weight `[2,1,1]` → 50/25/25,
   * 80/20 → `[4,1]`, tri-stable → `[1,1,1]`.
   */
  composition?: { symbol: VisualSymbol; weight: number }[]
}

const SPOKE_DEFAULT_FEE_TIER: Record<BorrowSpokeId, string> = {
  "uni-v2": "0.30%",
  "uni-v3-stable": "0.05%",
  "uni-v3-bluechip": "0.30%",
  "uni-v3-gov": "1.00%",
  "curve-stable": "0.04%",
  "curve-correlated": "0.04%",
  "curve-crypto": "0.40%",
  "bal-stable": "0.04%",
  "bal-correlated": "0.04%",
  "bal-weighted": "0.30%",
  "bal-boosted": "0.10%",
  "bal-reclamm": "0.30%",
  "aero-basic-stable": "0.05%",
  "aero-basic-volatile": "0.30%",
  "aero-slipstream-bluechip": "0.05%",
  "aero-concentrated-stocks": "0.05%",
  "uni-robinhood-stocks": "0.30%",
}

const POOL_SEEDS: Record<BorrowSpokeId, PoolSeed[]> = {
  "uni-v2": [
    { pair: ["WETH", "USDC"], trendUp: true },
    { pair: ["WBTC", "WETH"], trendUp: true },
    { pair: ["WETH", "DAI"], trendUp: false },
    { pair: ["WETH", "USDT"], trendUp: true },
    { pair: ["WBTC", "USDC"], trendUp: false },
  ],
  "uni-v3-stable": [
    { pair: ["USDC", "USDT"], trendUp: true },
    { pair: ["DAI", "USDC"], trendUp: true },
    { pair: ["crvUSD", "USDC"], trendUp: true },
    { pair: ["EURC", "USDC"], trendUp: false },
  ],
  "uni-v3-bluechip": [
    { pair: ["WETH", "USDC"], trendUp: true },
    { pair: ["WBTC", "WETH"], trendUp: true },
    { pair: ["WBTC", "USDC"], trendUp: false },
    { pair: ["WETH", "USDT"], trendUp: true },
    { pair: ["cbBTC", "WETH"], trendUp: true },
  ],
  "uni-v3-gov": [
    { pair: ["AAVE", "WETH"], trendUp: true },
    { pair: ["UNI", "WETH"], trendUp: false },
    { pair: ["CRV", "WETH"], trendUp: false },
    { pair: ["LDO", "WETH"], trendUp: true },
  ],
  "curve-stable": [
    { pair: ["USDC", "USDT"], trendUp: true },
    {
      pair: ["DAI", "USDC"],
      name: "DAI / USDC / USDT",
      trendUp: true,
      composition: [
        { symbol: "DAI", weight: 1 },
        { symbol: "USDC", weight: 1 },
        { symbol: "USDT", weight: 1 },
      ],
    },
    { pair: ["crvUSD", "USDC"], trendUp: true },
    { pair: ["USDe", "USDC"], trendUp: true },
    { pair: ["FRAX", "USDC"], trendUp: false },
  ],
  "curve-correlated": [
    { pair: ["ETH", "stETH"], trendUp: true },
    { pair: ["ETH", "wstETH"], trendUp: true },
    { pair: ["rETH", "ETH"], trendUp: true },
    { pair: ["cbETH", "ETH"], trendUp: false },
    { pair: ["weETH", "ETH"], trendUp: true },
  ],
  "curve-crypto": [
    { pair: ["USDT", "ETH"], trendUp: true },
    { pair: ["WBTC", "ETH"], trendUp: true },
    { pair: ["CRV", "ETH"], trendUp: false },
    {
      pair: ["WBTC", "ETH"],
      name: "USDC / WBTC / ETH",
      trendUp: true,
      composition: [
        { symbol: "USDC", weight: 1 },
        { symbol: "WBTC", weight: 1 },
        { symbol: "ETH", weight: 1 },
      ],
    },
  ],
  "bal-stable": [
    {
      pair: ["USDC", "DAI"],
      name: "USDC / DAI / USDT",
      trendUp: true,
      composition: [
        { symbol: "USDC", weight: 1 },
        { symbol: "DAI", weight: 1 },
        { symbol: "USDT", weight: 1 },
      ],
    },
    { pair: ["GHO", "USDC"], trendUp: true },
    { pair: ["EURC", "USDC"], trendUp: false },
    { pair: ["sDAI", "USDC"], trendUp: true },
  ],
  "bal-correlated": [
    { pair: ["wstETH", "WETH"], trendUp: true },
    { pair: ["rETH", "WETH"], trendUp: true },
    { pair: ["cbETH", "WETH"], trendUp: false },
    { pair: ["weETH", "WETH"], trendUp: true },
  ],
  "bal-weighted": [
    {
      pair: ["WETH", "AAVE"],
      name: "80/20 WETH/AAVE",
      trendUp: true,
      composition: [
        { symbol: "WETH", weight: 4 },
        { symbol: "AAVE", weight: 1 },
      ],
    },
    {
      pair: ["BAL", "WETH"],
      name: "80/20 BAL/WETH",
      trendUp: false,
      composition: [
        { symbol: "BAL", weight: 4 },
        { symbol: "WETH", weight: 1 },
      ],
    },
    {
      pair: ["GNO", "WETH"],
      name: "80/20 GNO/WETH",
      trendUp: true,
      composition: [
        { symbol: "GNO", weight: 4 },
        { symbol: "WETH", weight: 1 },
      ],
    },
    {
      pair: ["AURA", "WETH"],
      name: "80/20 AURA/WETH",
      trendUp: false,
      composition: [
        { symbol: "AURA", weight: 4 },
        { symbol: "WETH", weight: 1 },
      ],
    },
  ],
  "bal-boosted": [
    {
      pair: ["USDC", "DAI"],
      name: "bb-a-USDC / bb-a-DAI / bb-a-USDT",
      trendUp: true,
      composition: [
        { symbol: "USDC", weight: 1 },
        { symbol: "DAI", weight: 1 },
        { symbol: "USDT", weight: 1 },
      ],
    },
    { pair: ["sDAI", "USDC"], trendUp: true },
    // Single-asset boosted pools (aToken wrapper + underlying) — value tracks the underlying.
    { pair: ["USDC", "USDC"], name: "waUSDC / USDC", trendUp: false, composition: [{ symbol: "USDC", weight: 1 }] },
    { pair: ["DAI", "DAI"], name: "waDAI / DAI", trendUp: true, composition: [{ symbol: "DAI", weight: 1 }] },
  ],
  "bal-reclamm": [
    { pair: ["WETH", "USDC"], trendUp: true },
    { pair: ["WETH", "USDT"], trendUp: true },
    { pair: ["WBTC", "WETH"], trendUp: false },
  ],
  "aero-basic-stable": [
    { pair: ["USDC", "DAI"], trendUp: true },
    { pair: ["USD+", "USDC"], trendUp: true },
    { pair: ["EURC", "USDC"], trendUp: false },
    { pair: ["USDC", "USDT"], trendUp: true },
  ],
  "aero-basic-volatile": [
    { pair: ["AERO", "USDC"], trendUp: true },
    { pair: ["DEGEN", "USDC"], trendUp: false },
    { pair: ["BRETT", "WETH"], trendUp: true },
    { pair: ["WELL", "WETH"], trendUp: false },
    { pair: ["AURA", "WETH"], trendUp: true },
  ],
  "aero-slipstream-bluechip": [
    { pair: ["WETH", "USDC"], trendUp: true },
    { pair: ["cbETH", "WETH"], trendUp: true },
    { pair: ["WETH", "cbBTC"], trendUp: true },
    { pair: ["cbBTC", "USDC"], trendUp: false },
  ],
  // Aerodrome tokenized-stock pools (USDC-quoted "…c" variants), ordered by real TVL.
  "aero-concentrated-stocks": [
    { pair: ["USDC", "NVDAc"], trendUp: true },
    { pair: ["USDC", "GOOGLc"], trendUp: true },
    { pair: ["USDC", "AAPLc"], trendUp: true },
    { pair: ["USDC", "METAc"], trendUp: true },
    { pair: ["USDC", "AMZNc"], trendUp: false },
    { pair: ["USDC", "MSFTc"], trendUp: true },
    { pair: ["USDC", "SPCXc"], trendUp: true },
    { pair: ["USDC", "TSLAc"], trendUp: false },
  ],
  // Uniswap Robinhood tokenized-stock pools (USDG-quoted).
  "uni-robinhood-stocks": [
    { pair: ["NVDA", "USDG"], trendUp: true },
    { pair: ["SPCX", "USDG"], trendUp: true },
    { pair: ["AAPL", "USDG"], trendUp: true },
    { pair: ["GOOGL", "USDG"], trendUp: true },
    { pair: ["TSLA", "USDG"], trendUp: false },
    { pair: ["META", "USDG"], trendUp: true },
    { pair: ["AMC", "USDG"], trendUp: false },
    { pair: ["MU", "USDG"], trendUp: true },
  ],
}

function slugify(input: string): string {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "")
}

/**
 * Deterministic 0..1 hash from a string. Used to derive per-pool jitter so
 * every pool gets a unique risk premium (and therefore a unique gauge score).
 */
function seededUnit(input: string): number {
  let h = 2166136261
  for (let i = 0; i < input.length; i++) {
    h ^= input.charCodeAt(i)
    h = Math.imul(h, 16777619)
  }
  return ((h >>> 0) % 10_000) / 10_000
}

/** Symbols we treat as USD-pegged (or otherwise price-stable) assets. */
const STABLE_SYMBOLS = new Set([
  "USDC",
  "USDT",
  "DAI",
  "USDE",
  "USDS",
  "USDP",
  "USD+",
  "SUSD",
  "SDAI",
  "CRVUSD",
  "GHO",
  "FRAX",
  "LUSD",
  "TUSD",
  "MIM",
  "PYUSD",
  "EURC",
  "EURS",
])

function isStableSymbol(symbol: string): boolean {
  return STABLE_SYMBOLS.has(symbol.toUpperCase())
}

function isStablePair(a: string, b: string): boolean {
  return isStableSymbol(a) && isStableSymbol(b)
}

function buildPoolTrendValues(poolId: string) {
  const seed = seededUnit(poolId)
  return [0.88, 0.91, 0.95, 0.93, 1.0].map((base, index) => Number((base + seed * 0.08 + index * 0.015).toFixed(3)))
}

function buildPoolCatalog(): BorrowPoolRow[] {
  const rows: BorrowPoolRow[] = []
  for (const spoke of BORROW_SPOKES) {
    const dex = DEX_BY_ID[spoke.dex]
    const seeds = POOL_SEEDS[spoke.id] ?? []
    seeds.forEach((seed, index) => {
      const [a, b] = seed.pair
      const name = seed.name ?? `${a} / ${b}`
      const visuals: [BorrowAssetVisual, BorrowAssetVisual] = [v(a), v(b)]
      // Normalized pool composition (fractions summing to 1). Equal-weight over the two-leg
      // `pair` unless the seed declares an explicit multi-token / weighted composition.
      const rawComposition = seed.composition ?? [
        { symbol: a, weight: 1 },
        { symbol: b, weight: 1 },
      ]
      const constituents: WeightedConstituent[] = normalizeWeights(rawComposition)
      const totalSeeds = seeds.length || 1
      const shareOfLiquidity = spoke.liquidityUsd * (0.55 + (0.4 * (totalSeeds - index)) / totalSeeds) * 0.6
      const availableUsd = Math.round(shareOfLiquidity / totalSeeds / 1000) * 1000
      const ltvJitter = ((index % 3) - 1) * 1.5
      const aprMid = spoke.aprApprox + ((index % 4) - 1.5) * 0.4
      const aprMin = Math.max(0.1, aprMid - 1.2)
      const aprMax = aprMid + 1.5
      const baseId = `${spoke.id}-${slugify(name)}`
      const id = rows.some((row) => row.id === baseId) ? `${baseId}-${index + 1}` : baseId
      const stablePair = isStablePair(a, b)
      // Stable/stable pairs: tight, low-bps jitter regardless of spoke base —
      // peg-to-peg exposure should always rank as low risk.
      // Everything else: wide, deterministic per-pool jitter (~±25% of base)
      // so no two pools collapse to the same gauge score.
      const jitterRange = stablePair ? 8 : Math.max(18, Math.round(spoke.riskPremiumBps * 0.25))
      const riskJitter = Math.round((seededUnit(id) - 0.5) * 2 * jitterRange)
      const riskPremiumBps = stablePair
        ? Math.min(32, Math.max(10, 18 + riskJitter))
        : Math.max(5, spoke.riskPremiumBps + riskJitter)
      const feeTier = seed.feeTier ?? SPOKE_DEFAULT_FEE_TIER[spoke.id] ?? "0.30%"
      const tvlUsd = Math.round(((shareOfLiquidity / totalSeeds) * (1.6 + (index % 4) * 0.18)) / 10000) * 10000
      rows.push({
        id,
        name,
        // Concise, meaningful venue (e.g. "Uniswap v2 LPs") — distinguishes the DEX + version
        // without the jargon LP-type description ("Constant-product LP tokens") that cluttered
        // the borrow table subtitle.
        venue: spoke.label,
        feeTier,
        tvlUsd: Math.max(tvlUsd, 500_000),
        spoke: spoke.id,
        ltv: Math.round((spoke.maxLtv + ltvJitter) * 10) / 10,
        dexes: [{ id: spoke.dex, label: dex.label }],
        borrowableTokens: spoke.borrowableTokens,
        aprMin: Math.round(aprMin * 10) / 10,
        aprMax: Math.round(aprMax * 10) / 10,
        availableUsd: Math.max(availableUsd, 250_000),
        riskPremiumBps,
        visuals,
        constituents,
        collateralExampleUsd: 1_500 + index * 320,
        trendUp: seed.trendUp ?? index % 2 === 0,
        trendValues: buildPoolTrendValues(id),
      })
    })
  }
  return rows
}

export const BORROW_POOL_CATALOG: BorrowPoolRow[] = buildPoolCatalog()

export const BORROW_PENDING_ROWS: PendingMarketRow[] = []

// ----- Borrowable assets ----------------------------------------------------

export const BORROWABLE_ASSETS: BorrowableAsset[] = [
  {
    id: "usdc",
    symbol: "USDC",
    name: "USD Coin",
    subtitle: "Stablecoin",
    borrowApr: 5.2,
    totalBorrowedUsd: 21_200_000,
    utilization: 68,
    availableUsd: 9_900_000,
    walletBalanceLabel: "12,400 USDC",
    hasWalletBalance: true,
    visual: v("USDC"),
    trendUp: true,
    category: "stable",
  },
  {
    id: "usdt",
    symbol: "USDT",
    name: "Tether USD",
    subtitle: "Stablecoin",
    borrowApr: 4.8,
    totalBorrowedUsd: 11_900_000,
    utilization: 54,
    availableUsd: 7_200_000,
    walletBalanceLabel: "3,200 USDT",
    hasWalletBalance: true,
    visual: v("USDT"),
    trendUp: true,
    category: "stable",
  },
  {
    id: "dai",
    symbol: "DAI",
    name: "DAI",
    subtitle: "MakerDAO stablecoin",
    borrowApr: 5.7,
    totalBorrowedUsd: 6_200_000,
    utilization: 41,
    availableUsd: 6_600_000,
    walletBalanceLabel: "800 DAI",
    hasWalletBalance: true,
    visual: v("DAI"),
    trendUp: false,
    category: "stable",
  },
  {
    id: "crvusd",
    symbol: "crvUSD",
    name: "crvUSD",
    subtitle: "Curve native stablecoin",
    borrowApr: 4.4,
    totalBorrowedUsd: 3_800_000,
    utilization: 46,
    availableUsd: 5_100_000,
    walletBalanceLabel: "0 crvUSD",
    hasWalletBalance: false,
    visual: v("crvUSD"),
    trendUp: true,
    category: "stable",
  },
  {
    id: "gho",
    symbol: "GHO",
    name: "GHO",
    subtitle: "Aave native stablecoin",
    borrowApr: 3.9,
    totalBorrowedUsd: 8_400_000,
    utilization: 48,
    availableUsd: 9_100_000,
    walletBalanceLabel: "0 GHO",
    hasWalletBalance: false,
    visual: v("GHO"),
    trendUp: true,
    category: "stable",
  },
  {
    id: "usdg",
    symbol: "USDG",
    name: "Global Dollar",
    subtitle: "Paxos USD stablecoin",
    borrowApr: 4.6,
    totalBorrowedUsd: 5_400_000,
    utilization: 44,
    availableUsd: 6_800_000,
    walletBalanceLabel: "0 USDG",
    hasWalletBalance: false,
    visual: v("USDG"),
    trendUp: true,
    category: "stable",
  },
  {
    id: "eurc",
    symbol: "EURC",
    name: "Euro Coin",
    subtitle: "Circle EUR stablecoin",
    borrowApr: 4.1,
    totalBorrowedUsd: 1_200_000,
    utilization: 32,
    availableUsd: 2_500_000,
    walletBalanceLabel: "0 EURC",
    hasWalletBalance: false,
    visual: v("EURC"),
    trendUp: true,
    category: "stable",
  },
  {
    id: "weth",
    symbol: "WETH",
    name: "Wrapped Ether",
    subtitle: "ERC-20 wrapped ETH",
    borrowApr: 4.1,
    totalBorrowedUsd: 18_300_000,
    utilization: 58,
    availableUsd: 12_900_000,
    walletBalanceLabel: "0 WETH",
    hasWalletBalance: false,
    visual: v("WETH"),
    trendUp: true,
    category: "eth",
  },
  {
    id: "eth",
    symbol: "ETH",
    name: "Ethereum",
    subtitle: "Native asset",
    borrowApr: 4.0,
    totalBorrowedUsd: 6_100_000,
    utilization: 55,
    availableUsd: 5_000_000,
    walletBalanceLabel: "0.420 ETH",
    hasWalletBalance: true,
    visual: v("ETH"),
    trendUp: true,
    category: "eth",
  },
  {
    id: "wbtc",
    symbol: "WBTC",
    name: "Wrapped Bitcoin",
    subtitle: "ERC-20 wrapped BTC",
    borrowApr: 3.7,
    totalBorrowedUsd: 4_800_000,
    utilization: 44,
    availableUsd: 6_100_000,
    walletBalanceLabel: "0 WBTC",
    hasWalletBalance: false,
    visual: v("WBTC"),
    trendUp: true,
    category: "btc",
  },
  {
    id: "cbbtc",
    symbol: "cbBTC",
    name: "Coinbase Wrapped BTC",
    subtitle: "Coinbase wrapped BTC",
    borrowApr: 3.9,
    totalBorrowedUsd: 2_100_000,
    utilization: 38,
    availableUsd: 3_400_000,
    walletBalanceLabel: "0 cbBTC",
    hasWalletBalance: false,
    visual: v("cbBTC"),
    trendUp: true,
    category: "btc",
  },
  {
    id: "steth",
    symbol: "stETH",
    name: "Lido Staked ETH",
    subtitle: "Liquid staking receipt",
    borrowApr: 3.4,
    totalBorrowedUsd: 5_400_000,
    utilization: 42,
    availableUsd: 7_500_000,
    walletBalanceLabel: "0 stETH",
    hasWalletBalance: false,
    visual: v("stETH"),
    trendUp: true,
    category: "eth",
  },
  {
    id: "wsteth",
    symbol: "wstETH",
    name: "Wrapped stETH",
    subtitle: "Rebase-less stETH wrapper",
    borrowApr: 3.4,
    totalBorrowedUsd: 4_200_000,
    utilization: 40,
    availableUsd: 6_600_000,
    walletBalanceLabel: "0 wstETH",
    hasWalletBalance: false,
    visual: v("wstETH"),
    trendUp: true,
    category: "eth",
  },
  {
    id: "reth",
    symbol: "rETH",
    name: "Rocket Pool ETH",
    subtitle: "rETH liquid staking",
    borrowApr: 3.5,
    totalBorrowedUsd: 1_600_000,
    utilization: 35,
    availableUsd: 3_100_000,
    walletBalanceLabel: "0 rETH",
    hasWalletBalance: false,
    visual: v("rETH"),
    trendUp: true,
    category: "eth",
  },
  {
    id: "cbeth",
    symbol: "cbETH",
    name: "Coinbase Wrapped ETH",
    subtitle: "Coinbase liquid staking",
    borrowApr: 3.6,
    totalBorrowedUsd: 1_100_000,
    utilization: 33,
    availableUsd: 2_400_000,
    walletBalanceLabel: "0 cbETH",
    hasWalletBalance: false,
    visual: v("cbETH"),
    trendUp: true,
    category: "eth",
  },
]

const BORROWABLE_ASSET_BY_SYMBOL = new Map(BORROWABLE_ASSETS.map((asset) => [asset.symbol.toUpperCase(), asset]))

export function getBorrowAssetsForSpoke(spokeId: BorrowSpokeId): BorrowableAsset[] {
  const spoke = SPOKE_BY_ID[spokeId]
  if (!spoke) return []

  return spoke.borrowableTokens
    .map((token) => BORROWABLE_ASSET_BY_SYMBOL.get(token.symbol.toUpperCase()))
    .filter((asset): asset is BorrowableAsset => Boolean(asset))
}

// ----- Supply meta (unchanged, still keyed to HOME_COLLATERAL_POOLS ids) ---

export const BORROW_SUPPLY_META: Record<
  string,
  {
    venue: string
    feesLabel: string
    feesUsd: number
    feesBreakdown: string
    accruedInterestUsd: number
    openedLabel: string
  }
> = {
  "eth-usdc": {
    venue: "Uni v3 · 0.3% · In Range",
    feesLabel: "$142.00",
    feesUsd: 142,
    feesBreakdown: "0.021 ETH + 42.11 USDC",
    accruedInterestUsd: 52.4,
    openedLabel: "May 14, 2026",
  },
  "usdc-usdt": {
    venue: "Uni v3 · 0.01% · Full Range",
    feesLabel: "$62.40",
    feesUsd: 62.4,
    feesBreakdown: "42.11 USDC + 20.29 USDT",
    accruedInterestUsd: 32.0,
    openedLabel: "May 19, 2026",
  },
  "wbtc-eth": {
    venue: "Uni v3 · 0.3% · In Range",
    feesLabel: "$79.60",
    feesUsd: 79.6,
    feesBreakdown: "0.0011 WBTC + 0.0094 ETH",
    accruedInterestUsd: 0,
    openedLabel: "—",
  },
}

// ----- Lookups --------------------------------------------------------------

export function getSpokeById(id: BorrowSpokeId): BorrowSpoke {
  return SPOKE_BY_ID[id] ?? BORROW_SPOKES[0]
}

export function getDexById(id: BorrowDexId): BorrowDex {
  return DEX_BY_ID[id] ?? BORROW_DEXES[0]
}

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
  eModeOnly?: boolean
}

export function filterPools(
  rows: BorrowPoolRow[],
  { text = "", dexes, spokes, eModeOnly }: PoolFilterOptions = {},
): BorrowPoolRow[] {
  const needle = text.trim().toLowerCase()
  const activeDexes = dexes && dexes.size > 0 ? dexes : null
  const activeSpokes = spokes && spokes.size > 0 ? spokes : null
  return rows.filter((row) => {
    const spoke = SPOKE_BY_ID[row.spoke]
    if (activeDexes && (!spoke || !activeDexes.has(spoke.dex))) return false
    if (activeSpokes && !activeSpokes.has(row.spoke)) return false
    if (eModeOnly && (!spoke || !spoke.eMode)) return false
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

export function groupByDex(rows: BorrowPoolRow[]): DexGroup[] {
  return BORROW_DEXES.map((dex) => {
    const dexSpokes = BORROW_SPOKES.filter((spoke) => spoke.dex === dex.id)
    const spokes = dexSpokes
      .map((spoke) => ({ spoke, rows: rows.filter((row) => row.spoke === spoke.id) }))
      .filter((entry) => entry.rows.length > 0)
    return { dex, spokes }
  }).filter((group) => group.spokes.length > 0)
}

/**
 * Sort pools into the exact order `groupByDex` renders them (DEX, then spoke; stable within a
 * spoke). Progressive reveal slices BEFORE grouping, so an unordered slice would drop newly
 * revealed rows into groups above the viewport and make the page jump.
 */
export function orderPoolsForDexGroups(rows: readonly BorrowPoolRow[]): BorrowPoolRow[] {
  const rank = new Map<string, number>()
  for (const dex of BORROW_DEXES) {
    for (const spoke of BORROW_SPOKES) if (spoke.dex === dex.id) rank.set(spoke.id, rank.size)
  }
  const last = rank.size
  return rows
    .map((row, index) => ({ row, index, rank: rank.get(row.spoke) ?? last }))
    .sort((a, b) => a.rank - b.rank || a.index - b.index)
    .map((entry) => entry.row)
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

export function homePoolSpoke(category: string): BorrowSpokeId {
  const label = category.toLowerCase()
  if (label.startsWith("stable")) return "uni-v3-stable"
  if (label.startsWith("bluechip") || label.startsWith("blue")) return "uni-v3-bluechip"
  return "aero-basic-volatile"
}

export const BORROWABLE_TOKEN_OPTIONS: Array<{ id: string; symbol: string }> = BORROWABLE_ASSETS.map((asset) => ({
  id: asset.id,
  symbol: asset.symbol,
}))
