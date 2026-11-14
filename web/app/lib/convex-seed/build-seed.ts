/**
 * Deterministic seed-row builder for the Convex market data layer.
 *
 * This is the SINGLE source that turns the in-repo borrow catalog + engine into
 * the row shapes Convex stores (see convex/schema.ts). It is PURE and
 * deterministic (seeded by market slug) so the seed is reproducible and
 * unit-testable without a Convex connection. A thin runner
 * (scripts/seed-convex.mjs) imports this, then batches the rows into the generic
 * upsert mutations in convex/seed.ts.
 *
 * Slug contract (must match how the detail pages query Convex):
 *   - asset markets → slug = SpokeBorrowableRecord.id  (e.g. "uni-v2:usdc")
 *   - pool markets  → slug = BorrowPoolRow.id           (e.g. "uni-v2-weth-usdc")
 */

import { BORROW_POOL_CATALOG, formatCompactUsd, poolLpTokenPriceUsd, type BorrowPoolRow } from "@/app/lib/borrow-sim"
import { SANDBOX_NOW } from "@/app/lib/deterministic"
import { listSpokeBorrowables, type SpokeBorrowableRecord } from "@/app/lib/borrow-system/registry"
import { prngFromString } from "@/app/lib/borrow-detail/prng"
import { computeAssetAllocationRows } from "@/app/lib/borrow-detail/allocation"
import { resolveBorrowablesForPool } from "@/app/lib/borrow-detail/cross-market"
import { buildInterestRateModelParams } from "@/app/lib/borrow-detail/protocol-parameters"
import { buildRiskParameterSet } from "@/app/lib/borrow-detail/risk-parameters"
import { buildParameterChangeRows, type SeedParameterChangeRow } from "./build-parameter-changes"
import {
  buildAssetRiskAssessment,
  buildLendRiskAssessment,
  buildMultiplyRiskAssessment,
  buildPoolRiskAssessment,
} from "@/app/lib/borrow-detail/risk-model"
import {
  buildAssetFaqs,
  buildLendFaqs,
  buildMultiplyAboutDescription,
  buildMultiplyFaqs,
  buildPoolFaqs,
} from "@/app/lib/borrow-detail/content-model"
import { getAssetAboutCard } from "@/app/lib/borrow-detail/asset.mock"
import { getPoolAboutCard } from "@/app/lib/borrow-detail/pool.mock"
import { LEND_MARKET_CATALOG } from "@/app/lib/lend-system/catalog"
import { MULTIPLY_MARKET_CATALOG } from "@/app/lib/multiply-system/catalog"
import type { LendMarket } from "@/app/lib/lend-engine/types"
import type { MultiplyMarketRecord } from "@/app/lib/multiply-engine/types"
import type { RiskAssessment } from "@/app/lib/borrow-detail/types"

// Phase C seed inputs (see design-decisions.md) — grouped, pre-derived arrays.
import { SPOKES_SEED_ROWS, DEXES_SEED_ROWS } from "./inputs/reference-seed"
import { BORROW_ASSETS_SEED_ROWS } from "./inputs/borrow-assets-seed"
import {
  MULTIPLY_IRM_SEED_ROWS,
  MULTIPLY_ALLOCATION_SEED_ROWS,
  MULTIPLY_TOKEN_PARAM_SEED_ROWS,
} from "./inputs/multiply-catalog-seed"
import {
  POOL_CONTRACT_SEED_ROWS,
  ASSET_CONTRACT_SEED_ROWS,
  LEND_CONTRACT_SEED_ROWS,
  MULTIPLY_CONTRACT_SEED_ROWS,
} from "./inputs/contract-addresses-seed"
import {
  TEST_WALLET_COLLATERAL_SEED_ROWS,
  TEST_WALLET_DEBTS_SEED_ROWS,
  TEST_WALLET_CLAIMS_SEED_ROWS,
} from "./inputs/test-wallet-portfolio-seed"

const DAY_MS = 86_400_000

export type SeedMarketRow = {
  scope: "asset" | "pool" | "lend" | "multiply"
  slug: string
  chainId: number
  name: string
  symbol: string
  venueLabel?: string
  category?: "stable" | "crypto" | "stock"
  description?: string
  iconUrl?: string
  spokeId?: string
  feeTier?: string
  maxLtvPct?: number
  /** Reserve factor percent for Key Statistics (e.g. 10 = 10%). */
  reserveFactorPct?: number
  /** Incentive rewards APY percent (0 = none / "No rewards"). */
  rewardsApyPct?: number
  visuals?: Array<{
    symbol: string
    shortLabel: string
    bgClassName: string
    textClassName: string
    iconUrl?: string
  }>
  resources?: Array<{ label: string; href: string }>
  /** Pool composition with normalized weights, for live LP-price recomputation (Σ weightᵢ×priceᵢ). */
  constituents?: Array<{ symbol: string; weight: number }>
  /**
   * Canonical USD price for the market, used by the onboarding starter-allocation gate.
   * The live token oracle (convex/prices.ts) only covers single-token bluechip symbols, so
   * pool markets (LP-pair symbols like "cbBTC/USDC") and long-tail lend markets (chain-name
   * symbols like "OP") have no oracle price. Seeding it here lets the claim gate resolve a
   * positive price for every market. Pool positions are USD-denominated, so their price is 1.
   */
  priceUsd?: number
  createdAt: number
}

export type SeedDailyStatRow = {
  slug: string
  day: string
  suppliedUsd: number
  borrowedUsd: number
  utilizationPct: number
  supplyApyPct: number
  borrowAprPct: number
  tvlUsd: number
  volumeUsd: number
  feesUsd: number
  priceUsd?: number
}

/** Product-siloed borrow daily stats (pool + asset). */
type SeedBorrowDailyStatRow = SeedDailyStatRow & { kind: "pool" | "asset" }

type SeedRevenueRow = {
  slug: string
  day: string
  interestFromBorrowersUsd: number
  interestToSuppliersUsd: number
  reserveTakeUsd: number
  rewardsDistributedUsd: number
  swapFeesUsd: number
}

/** Product-siloed borrow revenue (pool + asset). */
type SeedBorrowRevenueRow = SeedRevenueRow & { kind: "pool" | "asset" }

type SeedRiskRow = {
  slug: string
  assessedAt: number
  premiumBps: number
  level: "low" | "moderate" | "elevated" | "high"
  score: number
  headline: string
  summary: string
  breakdown: {
    id: string
    label: string
    bps: number
    level: "low" | "moderate" | "elevated" | "high"
    description: string
  }[]
  metrics: { id: string; label: string; value: string; hint?: string }[]
}

/** Product-siloed borrow risk assessment (pool + asset). */
type SeedBorrowRiskAssessmentRow = SeedRiskRow & { kind: "pool" | "asset" }

type SeedWalletEventRow = {
  slug: string
  wallet: string
  kind: "supply" | "withdraw" | "borrow" | "repay"
  amountUsd: number
  txHash: string
  blockNumber: number
  at: number
}

/** One per (asset, pool) — the latest-day allocation snapshot. Keyed by both slugs;
 *  the push script resolves each to a `markets._id` before writing. */
type SeedAllocationRow = {
  assetSlug: string
  poolSlug: string
  day: string
  valueUsd: number
  sharePct: number
  utilizationPct: number
  borrowAprPct: number
}

/** Static editorial content (About description + stats, parameter-change history, FAQs). */
type SeedContentRow = {
  slug: string
  description: string
  stats: { label: string; value: string; href?: string }[]
  history: { date: string; title: string; description?: string }[]
  faqs: { question: string; answer: string }[]
}

/** Product-siloed borrow content (pool + asset). */
type SeedBorrowContentRow = SeedContentRow & { kind: "pool" | "asset" }

type SeedRiskParameterRow = {
  slug: string
  kind?: "pool" | "asset"
  parameters: Array<{ id: string; label: string; value: string; description?: string }>
  updatedAt: number
  source: "seed"
}

type SeedInterestRateModelRow = {
  slug: string
  optimalUtilizationPct: number
  slopeBelowOptimalPct: number
  slopeAboveOptimalPct: number
  baseBorrowRatePct: number
  updatedAt: number
  source: "seed"
}

type SeedLiquidationDailyRow = {
  slug: string
  day: string
  liquidationsCount: number
  collateralSeizedUsd: number
  debtRepaidUsd: number
  liquidationBonusUsd: number
  collateralAtRiskUsd: number
  walletsAtRisk: number
  walletsEligibleForLiquidation: number
  badDebtUsd: number
  walletsWithBadDebt: number
}

type SeedBorrowableEdgeRow = {
  poolSlug: string
  assetSlug: string
  name: string
  symbol: string
  borrowAprPct: number
}

export type SeedData = {
  markets: SeedMarketRow[]
  borrowMarkets: Array<Omit<SeedMarketRow, "scope"> & { kind: "pool" | "asset" }>
  lendMarkets: Array<Omit<SeedMarketRow, "scope">>
  multiplyMarkets: Array<Omit<SeedMarketRow, "scope">>
  dailyStats: SeedDailyStatRow[]
  borrowDailyStats: SeedBorrowDailyStatRow[]
  lendDailyStats: SeedDailyStatRow[]
  multiplyDailyStats: SeedDailyStatRow[]
  revenue: SeedRevenueRow[]
  borrowRevenueDaily: SeedBorrowRevenueRow[]
  lendRevenueDaily: SeedRevenueRow[]
  multiplyRevenueDaily: SeedRevenueRow[]
  risk: SeedRiskRow[]
  borrowRiskAssessments: SeedBorrowRiskAssessmentRow[]
  lendRiskAssessments: SeedRiskRow[]
  multiplyRiskAssessments: SeedRiskRow[]
  walletEvents: SeedWalletEventRow[]
  allocation: SeedAllocationRow[]
  content: SeedContentRow[]
  borrowMarketContent: SeedBorrowContentRow[]
  lendMarketContent: SeedContentRow[]
  multiplyMarketContent: SeedContentRow[]
  borrowRiskParameters: SeedRiskParameterRow[]
  borrowInterestRateModels: SeedInterestRateModelRow[]
  borrowLiquidationDaily: SeedLiquidationDailyRow[]
  borrowPoolBorrowables: SeedBorrowableEdgeRow[]
  lendRiskParameters: SeedRiskParameterRow[]
  lendInterestRateModels: SeedInterestRateModelRow[]
  multiplyRiskParameters: SeedRiskParameterRow[]
  multiplyLiquidationDaily: SeedLiquidationDailyRow[]
  parameterChanges: SeedParameterChangeRow[]

  // ---------------------------------------------------------------------------
  // Phase C additions — one field per new Convex table. All optional so the
  // existing seed pipeline keeps working while individual table writers land
  // per-commit.
  // ---------------------------------------------------------------------------
  spokes?: SeedSpokeRow[]
  dexes?: SeedDexRow[]
  borrowAssets?: SeedBorrowAssetRow[]
  multiplyInterestRateModels?: SeedMultiplyIrmRow[]
  multiplyMarketAllocations?: SeedMultiplyAllocationRow[]
  multiplyTokenParameters?: SeedMultiplyTokenParamRow[]
  poolContractAddresses?: SeedContractAddressRow[]
  assetContractAddresses?: SeedContractAddressRow[]
  lendContractAddresses?: SeedContractAddressRow[]
  multiplyContractAddresses?: SeedContractAddressRow[]
  walletCollateralPositions?: SeedWalletCollateralPositionRow[]
  walletDebts?: SeedWalletDebtRow[]
  walletClaimPositions?: SeedWalletClaimPositionRow[]
}

// -----------------------------------------------------------------------------
// Phase C row types — seed shapes matching convex/schema.ts additions.
// -----------------------------------------------------------------------------

export type SeedTokenVisual = {
  symbol: string
  iconUrl: string
  shortLabel: string
  bgClass: string
  textClass: string
}

export type SeedSpokeRow = {
  id: string
  slug: string
  dex: string
  label: string
  description: string
  eMode?: string
  maxLtvPct: number
  aprApproxPct: number
  riskPremiumBps: number
  liquidityUsd: number
  liquidationUsdApprox: number
  bgClass: string
  textClass: string
  borrowableTokens: SeedTokenVisual[]
  isSmartSpoke: boolean
}

export type SeedDexRow = { id: string; label: string; tvlUsd: number; bgClass: string; textClass: string }

export type SeedBorrowAssetRow = {
  id: string
  spokeId: string
  baseAssetId: string
  name: string
  symbol: string
  subtitle: string
  category: string
  contextLabel: string
  displayVisual: SeedTokenVisual
  baseBorrowAprPct: number
  totalCapacityUsd: number
  utilizationPct: number
  totalBorrowedUsd: number
  availableUsd: number
  reserveFactorPct?: number
  marketIds: string[]
}

export type SeedMultiplyIrmRow = {
  slug: string
  optimalUtilizationPct: number
  slopeBelowOptimalPct: number
  slopeAboveOptimalPct: number
  baseBorrowRatePct: number
}

export type SeedMultiplyAllocationRow = {
  marketSlug: string
  rowKey: string
  poolSlug: string
  poolName: string
  venueLabel: string
  sharePct: number
  valueUsd: number
  utilizationPct: number
  borrowAprPct: number
  collateralFactorPct: number
}

export type SeedMultiplyTokenParamRow = {
  symbol: string
  supplyApyPct: number
  borrowAprPct: number
  availableUsd: number
  collateralFactorPct: number
  liquidationThresholdPct: number
  iconUrl: string
}

export type SeedContractAddressRow = {
  slug: string
  salt: string
  address: string
  label: string
  href: string
  chain: string
  isSynthetic: boolean
}

export type SeedWalletCollateralPositionRow = {
  wallet: string
  homePoolId: string
  marketId: string
  name: string
  venueLabel: string
  category: string
  collateralUsd: number
  maxLtvPct: number
  borrowPowerUsd: number
  liquidationUsd: number
  pairAprPct: number
}

export type SeedWalletDebtRow = {
  wallet: string
  homePoolId: string
  marketId: string
  debtAssetId: string
  amountUsd: number
}

export type SeedWalletClaimBreakdownRow = {
  symbol: string
  amountLabel: string
  amountToken: number
  usdValue: number
  visualSymbol: string
}

export type SeedWalletClaimPositionRow = {
  wallet: string
  claimId: string
  homePoolId: string
  marketId: string
  name: string
  subtitle: string
  totalUsd: number
  breakdown: SeedWalletClaimBreakdownRow[]
}

/** Re-export TEST_WALLET_ADDRESS at its original path so existing consumers keep working. */
export { TEST_WALLET_ADDRESS } from "./test-wallet"

type BuildSeedOptions = {
  /** How many trailing daily rows to generate per market (drives 1Y/ALL chart depth). */
  days?: number
  /** End date (ms, UTC) of the daily window; defaults to "now". Pass a fixed value for reproducible tests. */
  asOf?: number
  /** Reserve factor applied to interest (supplier vs protocol split). */
  reserveFactor?: number
  /** Latest-day aggregate TVL targets the seed calibrates to (the canonical economy). */
  poolTvlTargetUsd?: number
  assetTvlTargetUsd?: number
}

const RESERVE_FACTOR_DEFAULT = 0.12

// Canonical economy aggregates (de-inflated). The raw catalog sums to ~$6.9B pools
// / ~$8.4B assets; the seed scales the latest day so the borrow hero reconciles to:
//   Total Collateral = pool TVL          = $1.6B
//   Outstanding Loans = asset TVL (≈ fully borrowed) = $700M
//   Available Credit  = collateral − loans = $900M
export const POOL_TVL_TARGET_USD = 1_600_000_000
export const ASSET_TVL_TARGET_USD = 700_000_000

function isoDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10)
}

function round(value: number, dp = 2): number {
  const f = 10 ** dp
  return Math.round(value * f) / f
}

function schemaCategory(category: string): "stable" | "crypto" {
  return category === "stable" ? "stable" : "crypto"
}

/**
 * Deterministic daily walk producing REALISTIC market history (not a smooth line):
 * a mean-reverting random walk anchored to a gentle trend, textured with several
 * sine harmonics + per-step noise. `days` points ending at `asOf`, clamped
 * non-negative, seeded by `${slug}:${metric}` so it's reproducible and each market
 * looks distinct. `noise` here is the per-step volatility (random-walk step size).
 */
function dailyWalk(
  slug: string,
  metric: string,
  base: number,
  asOf: number,
  days: number,
  opts: { drift?: number; noise?: number; wave?: number; ramp?: boolean; startFraction?: number } = {},
): { day: string; value: number }[] {
  const rand = prngFromString(`${slug}:${metric}`)
  const ramp = opts.ramp ?? false
  const drift = opts.drift ?? 1.06
  const volatility = opts.noise ?? 0.05
  const waveAmp = opts.wave ?? 0.07
  const startFraction = opts.startFraction ?? 0.06
  // Random phases so harmonics don't line up across markets.
  const phaseA = rand() * Math.PI * 2
  const phaseB = rand() * Math.PI * 2
  const phaseC = rand() * Math.PI * 2
  const out: { day: string; value: number }[] = []
  // RAMP metrics (TVL / supplied — balances) grow organically from a small fraction of
  // `base` up to `base` at the tip, so "All" reads as a market that filled from ~0 to its
  // current size instead of a flat band pinned at the current value. FLAT metrics
  // (utilization, APY — rates, not balances) oscillate around `base` the whole window.
  const start = ramp ? base * startFraction : base
  let level = start
  for (let i = 0; i < days; i++) {
    const progress = days <= 1 ? 1 : i / (days - 1)
    const target = ramp
      ? start + (base - start) * (progress * progress * (3 - 2 * progress)) // smoothstep → base at the tip
      : base * (1 + (drift - 1) * progress)
    // Anchor volatility + texture to the CURRENT level for ramp metrics (so early days
    // wiggle proportionally small and the growth trend dominates the noise — no random
    // down-endings), and to `base` for flat metrics.
    const anchor = ramp ? level : base
    level += (target - level) * (ramp ? 0.12 : 0.08) + (rand() * 2 - 1) * anchor * volatility
    // Multi-frequency texture (slow swings + faster chop).
    const wave =
      anchor *
      waveAmp *
      (Math.sin(progress * Math.PI * 8 + phaseA) * 0.5 +
        Math.sin(progress * Math.PI * 23 + phaseB) * 0.32 +
        Math.sin(progress * Math.PI * 57 + phaseC) * 0.18)
    const value = Math.max(ramp ? start * 0.35 : base * 0.05, level + wave)
    const day = isoDay(asOf - (days - 1 - i) * DAY_MS)
    out.push({ day, value })
  }
  return out
}

function poolMarketRow(pool: BorrowPoolRow, createdAt: number): SeedMarketRow {
  const [a, b] = pool.visuals
  return {
    scope: "pool",
    slug: pool.id,
    chainId: 1,
    name: pool.name,
    symbol: `${a?.symbol ?? "LP"}/${b?.symbol ?? "LP"}`,
    venueLabel: pool.venue,
    description: `${pool.name} liquidity position on ${pool.venue}.`,
    spokeId: pool.spoke,
    feeTier: pool.feeTier,
    maxLtvPct: pool.ltv,
    reserveFactorPct: Math.round(RESERVE_FACTOR_DEFAULT * 100),
    rewardsApyPct: 0,
    visuals: pool.visuals.map((visual) => ({
      symbol: visual.symbol,
      shortLabel: visual.shortLabel,
      bgClassName: visual.bgClass,
      textClassName: visual.textClass,
      iconUrl: visual.iconUrl,
    })),
    resources: [{ label: "Open market", href: `/borrow/markets/${pool.id}` }],
    // Server-side LP token price, derived with the SAME helper the client uses to size
    // pledged collateral (borrow-system/mock.ts). assertBorrowSolvent revalues a pledge's
    // 18-decimal LP-token amount as `tokens * priceUsd`; with the old nominal $1 here a
    // multi-thousand-dollar pledge (a few LP tokens) valued at only a few dollars, so the
    // server rejected borrows the client preview allowed. `pools.lpTokenPriceUsd` (unseeded
    // in this deployment) still takes precedence when present.
    priceUsd: poolLpTokenPriceUsd(pool),
    // Pool composition + weights, so the Convex oracle job (prices.refreshPoolLpPrices) can
    // recompute this LP price live as Σ(weightᵢ × priceᵢ) instead of leaving the seed value frozen.
    constituents: pool.constituents.map((c) => ({ symbol: c.symbol, weight: c.weight })),
    createdAt,
  }
}

function assetMarketRow(asset: SpokeBorrowableRecord, createdAt: number): SeedMarketRow {
  return {
    scope: "asset",
    slug: asset.id,
    chainId: 1,
    name: asset.name,
    symbol: asset.symbol,
    category: schemaCategory(asset.category),
    description: asset.subtitle,
    iconUrl: asset.visual.iconUrl,
    spokeId: asset.spokeId,
    reserveFactorPct: Math.round(RESERVE_FACTOR_DEFAULT * 100),
    rewardsApyPct: 0,
    visuals: [
      {
        symbol: asset.visual.symbol,
        shortLabel: asset.visual.shortLabel,
        bgClassName: asset.visual.bgClass,
        textClassName: asset.visual.textClass,
        iconUrl: asset.visual.iconUrl,
      },
    ],
    resources: [{ label: "Open asset", href: `/borrow/assets/${asset.id}` }],
    createdAt,
  }
}

function lendMarketRow(market: LendMarket, createdAt: number): SeedMarketRow {
  return {
    scope: "lend",
    slug: market.marketId,
    chainId: market.chainId,
    name: market.asset.name,
    symbol: market.asset.symbol,
    // Prefer the catalog's group-derived category (stablecoins → "stable", tokenized
    // equities → "stock"); fall back to the risk-tier heuristic for any legacy market.
    category: market.category ?? (market.riskTier === "low" ? "stable" : "crypto"),
    description: `Supply ${market.asset.symbol} to the Avana lending market.`,
    reserveFactorPct: Math.round(market.reserveFactor * 1000) / 10,
    rewardsApyPct: Math.round(market.rewardsApy * 10000) / 100,
    resources: [{ label: "Open market", href: `/lend/markets/${market.marketId}` }],
    // Long-tail lend assets (OP, ARB, AERO, …) aren't in the single-token oracle, so carry
    // the catalog's own USD price for the onboarding gate. Lend positions store USD, so this
    // only needs to be positive.
    priceUsd: market.assetPriceUsd,
    createdAt,
  }
}

/**
 * Daily stats for a lend (single-asset supply) market. Unlike the borrow asset/pool
 * generator, the supply APY is GIVEN by the catalog (walked around it) rather than
 * derived from a borrow rate; the borrow APR is back-derived for display only.
 */
function dailyStatsForLendMarket(
  slug: string,
  base: { suppliedUsd: number; utilizationPct: number; supplyApyPct: number; reserveFactor: number; priceUsd: number },
  asOf: number,
  days: number,
): SeedDailyStatRow[] {
  const supplied = dailyWalk(slug, "supplied", base.suppliedUsd, asOf, days, { ramp: true, noise: 0.04 })
  const util = dailyWalk(slug, "util", base.utilizationPct, asOf, days, { drift: 1.0, noise: 0.06, wave: 0.05 })
  const apy = dailyWalk(slug, "supplyapy", base.supplyApyPct, asOf, days, { drift: 1.0, noise: 0.05, wave: 0.04 })
  return supplied.map((s, i) => {
    const utilizationPct = Math.min(99, Math.max(1, round(util[i]!.value, 2)))
    const suppliedUsd = round(s.value, 0)
    const borrowedUsd = round((suppliedUsd * utilizationPct) / 100, 0)
    const supplyApyPct = round(Math.max(0.01, apy[i]!.value), 2)
    // Implied borrow APR from supply = borrow · utilization · (1 − reserveFactor).
    const borrowAprPct = round(
      supplyApyPct / Math.max(0.05, utilizationPct / 100) / Math.max(0.5, 1 - base.reserveFactor),
      2,
    )
    return {
      slug,
      day: s.day,
      suppliedUsd,
      borrowedUsd,
      utilizationPct,
      supplyApyPct,
      borrowAprPct,
      tvlUsd: suppliedUsd,
      volumeUsd: 0,
      feesUsd: round((borrowedUsd * borrowAprPct) / 100 / 365, 2),
      priceUsd: base.priceUsd,
    }
  })
}

function multiplyMarketRow(market: MultiplyMarketRecord, createdAt: number): SeedMarketRow {
  const reserveFactorPct = market.risk.riskTier === "low" ? 10 : market.risk.riskTier === "medium" ? 12 : 15
  return {
    scope: "multiply",
    slug: market.id,
    chainId: 1,
    name: `${market.collateralAsset.symbol} / ${market.borrowAsset.symbol}`,
    symbol: market.collateralAsset.symbol,
    category: market.risk.riskTier === "low" ? "stable" : "crypto",
    description: `Multiply ${market.collateralAsset.symbol} exposure against ${market.borrowAsset.symbol}.`,
    // Convex hydration reads maxLtvPct into the multiply state's risk.collateralFactor;
    // omitting it silently used the catalog's default and tripped the hydration-telemetry
    // warn. Source from the catalog's maxLtv (already declared per-market).
    maxLtvPct: market.risk.maxLtv * 100,
    reserveFactorPct,
    rewardsApyPct: 0,
    resources: [{ label: "Open market", href: `/multiply/markets/${market.id}` }],
    // Collateral symbols are bluechips the oracle already covers; carry the catalog price
    // too so the gate stays satisfied even if the oracle is briefly stale/unseeded.
    priceUsd: market.collateralAsset.priceUsd,
    createdAt,
  }
}

/**
 * Daily stats for a multiply (leveraged loop) market. "Supplied" is the market's
 * available loop liquidity (TVL); supply + borrow APY are both given by the catalog.
 */
function dailyStatsForMultiplyMarket(
  slug: string,
  base: { suppliedUsd: number; utilizationPct: number; supplyApyPct: number; borrowAprPct: number; priceUsd: number },
  asOf: number,
  days: number,
): SeedDailyStatRow[] {
  const supplied = dailyWalk(slug, "supplied", base.suppliedUsd, asOf, days, { ramp: true, noise: 0.05 })
  const util = dailyWalk(slug, "util", base.utilizationPct, asOf, days, { drift: 1.0, noise: 0.06, wave: 0.05 })
  const apy = dailyWalk(slug, "supplyapy", base.supplyApyPct, asOf, days, { drift: 1.0, noise: 0.05, wave: 0.04 })
  return supplied.map((s, i) => {
    const utilizationPct = Math.min(99, Math.max(1, round(util[i]!.value, 2)))
    const suppliedUsd = round(s.value, 0)
    const borrowedUsd = round((suppliedUsd * utilizationPct) / 100, 0)
    const supplyApyPct = round(Math.max(0.01, apy[i]!.value), 2)
    return {
      slug,
      day: s.day,
      suppliedUsd,
      borrowedUsd,
      utilizationPct,
      supplyApyPct,
      borrowAprPct: base.borrowAprPct,
      tvlUsd: suppliedUsd,
      volumeUsd: 0,
      feesUsd: round((borrowedUsd * base.borrowAprPct) / 100 / 365, 2),
      priceUsd: base.priceUsd,
    }
  })
}

function dailyStatsForMarket(
  slug: string,
  scope: "asset" | "pool",
  base: { suppliedUsd: number; utilizationPct: number; borrowAprPct: number },
  asOf: number,
  days: number,
): SeedDailyStatRow[] {
  const supplied = dailyWalk(slug, "supplied", base.suppliedUsd, asOf, days, { ramp: true, noise: 0.04 })
  const util = dailyWalk(slug, "util", base.utilizationPct, asOf, days, { drift: 1.0, noise: 0.06, wave: 0.05 })
  const apr = dailyWalk(slug, "apr", base.borrowAprPct, asOf, days, { drift: 1.0, noise: 0.05, wave: 0.04 })
  return supplied.map((s, i) => {
    const utilizationPct = Math.min(99, Math.max(1, round(util[i]!.value, 2)))
    const suppliedUsd = round(s.value, 0)
    const borrowedUsd = round((suppliedUsd * utilizationPct) / 100, 0)
    const borrowAprPct = round(Math.max(0.25, apr[i]!.value), 2)
    const supplyApyPct = round(borrowAprPct * (utilizationPct / 100) * 0.85, 2)
    const volumeUsd = scope === "pool" ? round(suppliedUsd * 0.12, 0) : 0
    const feesUsd = round((borrowedUsd * borrowAprPct) / 100 / 365, 2)
    return {
      slug,
      day: s.day,
      suppliedUsd,
      borrowedUsd,
      utilizationPct,
      supplyApyPct,
      borrowAprPct,
      tvlUsd: suppliedUsd,
      volumeUsd,
      feesUsd,
    }
  })
}

function revenueForMarket(stats: SeedDailyStatRow[], reserveFactor: number): SeedRevenueRow[] {
  return stats.map((row) => {
    const interestFromBorrowersUsd = round((row.borrowedUsd * row.borrowAprPct) / 100 / 365, 2)
    const reserveTakeUsd = round(interestFromBorrowersUsd * reserveFactor, 2)
    const interestToSuppliersUsd = round(interestFromBorrowersUsd - reserveTakeUsd, 2)
    return {
      slug: row.slug,
      day: row.day,
      interestFromBorrowersUsd,
      interestToSuppliersUsd,
      reserveTakeUsd,
      rewardsDistributedUsd: round(interestFromBorrowersUsd * 0.25, 2),
      swapFeesUsd: row.volumeUsd > 0 ? round(row.volumeUsd * 0.0005, 2) : 0,
    }
  })
}

function contractAddressForSeed(slug: string, salt: string) {
  const seed = `${slug}:${salt}`
  let hash = 0x811c9dc5
  for (let index = 0; index < seed.length; index += 1) {
    hash ^= seed.charCodeAt(index)
    hash = Math.imul(hash, 0x01000193)
  }
  const chunk = (hash >>> 0).toString(16).padStart(8, "0").toUpperCase()
  return `0x${chunk}${chunk}${chunk}${chunk}${chunk}`.slice(0, 42)
}

function shortAddress(address: string) {
  return `${address.slice(0, 6)}...${address.slice(-4)}`
}

function contractStatForSeed(label: string, slug: string, salt: string) {
  const address = contractAddressForSeed(slug, salt)
  return {
    label,
    value: shortAddress(address),
    href: `https://etherscan.io/address/${address}`,
  }
}

function isStablePool(row: BorrowPoolRow) {
  const stables = new Set(["USDC", "USDT", "DAI", "GHO", "FRAX", "CRVUSD", "USDS"])
  return row.visuals.every((visual) => stables.has(visual.symbol.toUpperCase()))
}

/** Deposit/borrow capacity labels derived from a market tip (must use post-calibration tips). */
export function borrowPoolCapacityLabels(suppliedUsd: number, availableUsd: number) {
  const supplyCapUsd = Math.max(25_000_000, Math.ceil((Math.max(0, suppliedUsd) * 1.75) / 1_000_000) * 1_000_000)
  const borrowCapUsd = Math.max(10_000_000, Math.ceil((Math.max(0, availableUsd) * 2.25) / 1_000_000) * 1_000_000)
  return {
    depositCapacityLabel: formatCompactUsd(supplyCapUsd),
    borrowCapacityLabel: formatCompactUsd(borrowCapUsd),
    supplyCapUsd,
    borrowCapUsd,
  }
}

function borrowAssetCapacityLabels(suppliedUsd: number, availableUsd: number) {
  return {
    depositCapacityLabel: formatCompactUsd(Math.max(25_000_000, Math.max(0, suppliedUsd) * 1.75)),
    borrowCapacityLabel: formatCompactUsd(Math.max(10_000_000, Math.max(0, availableUsd) * 2)),
  }
}

function borrowPoolRiskParameterRow(pool: BorrowPoolRow, asOf: number): SeedRiskParameterRow {
  const caps = borrowPoolCapacityLabels(pool.tvlUsd, pool.availableUsd)
  return {
    slug: pool.id,
    kind: "pool",
    parameters: buildRiskParameterSet({
      collateralFactorPct: pool.ltv,
      liquidationThresholdPct: Math.min(95, Math.round((pool.ltv + 5) * 10) / 10),
      depositCapacityLabel: caps.depositCapacityLabel,
      borrowCapacityLabel: caps.borrowCapacityLabel,
      liquidationPenaltyPct: isStablePool(pool) ? 5 : 7,
      collateralFactorDescription: "Maximum borrow power when this LP position is used as collateral.",
    }),
    updatedAt: asOf,
    source: "seed",
  }
}

function borrowAssetRiskParameterRow(asset: SpokeBorrowableRecord, asOf: number): SeedRiskParameterRow {
  const suppliedUsd = asset.availableUsd + asset.totalBorrowedUsd
  const caps = borrowAssetCapacityLabels(suppliedUsd, asset.availableUsd)
  return {
    slug: asset.id,
    kind: "asset",
    parameters: buildRiskParameterSet({
      collateralFactorPct: 75,
      depositCapacityLabel: caps.depositCapacityLabel,
      borrowCapacityLabel: caps.borrowCapacityLabel,
      liquidationPenaltyPct: asset.category === "stable" ? 5 : 7,
    }),
    updatedAt: asOf,
    source: "seed",
  }
}

/**
 * Must run after `calibrateToTargets`: rewrites the capacity labels from the calibrated
 * latest-day tip so Risk Parameters match live market size, not the raw catalog.
 */
function resyncBorrowRiskParameterCapsFromDailyTips(
  riskParameters: SeedRiskParameterRow[],
  dailyStats: ReadonlyArray<{ slug: string; day: string; suppliedUsd: number; borrowedUsd: number }>,
  lastDay: string,
) {
  const tipBySlug = new Map<string, { suppliedUsd: number; availableUsd: number }>()
  for (const row of dailyStats) {
    if (row.day !== lastDay) continue
    tipBySlug.set(row.slug, {
      suppliedUsd: row.suppliedUsd,
      availableUsd: Math.max(0, row.suppliedUsd - row.borrowedUsd),
    })
  }
  for (const risk of riskParameters) {
    const tip = tipBySlug.get(risk.slug)
    if (!tip) continue
    const caps =
      risk.kind === "asset"
        ? borrowAssetCapacityLabels(tip.suppliedUsd, tip.availableUsd)
        : borrowPoolCapacityLabels(tip.suppliedUsd, tip.availableUsd)
    risk.parameters = risk.parameters.map((parameter) => {
      if (parameter.id === "depositCapacity") return { ...parameter, value: caps.depositCapacityLabel }
      if (parameter.id === "borrowCapacity") return { ...parameter, value: caps.borrowCapacityLabel }
      return parameter
    })
  }
}

function interestRateModelRow(slug: string, borrowAprPct: number, asOf: number): SeedInterestRateModelRow {
  const params = buildInterestRateModelParams(slug, borrowAprPct)
  return { slug, ...params, updatedAt: asOf, source: "seed" }
}

function liquidationDailyForSlug(slug: string, asOf: number): SeedLiquidationDailyRow[] {
  const rand = prngFromString(`liq:${slug}`)
  const today = isoDay(asOf)
  const yesterday = isoDay(asOf - DAY_MS)
  const base = {
    liquidationsCount: Math.floor(rand() * 20) + 2,
    collateralSeizedUsd: round(rand() * 2_000_000 + 200_000, 0),
    debtRepaidUsd: round(rand() * 1_800_000 + 180_000, 0),
    liquidationBonusUsd: round(rand() * 100_000 + 10_000, 0),
    collateralAtRiskUsd: round(rand() * 12_000_000 + 1_000_000, 0),
    walletsAtRisk: Math.floor(rand() * 80) + 5,
    walletsEligibleForLiquidation: Math.floor(rand() * 15) + 1,
    badDebtUsd: round(rand() * 5_000 + 100, 2),
    walletsWithBadDebt: Math.floor(rand() * 5),
  }
  const prior = {
    ...base,
    liquidationsCount: Math.max(0, base.liquidationsCount - Math.floor(rand() * 5)),
    collateralAtRiskUsd: round(base.collateralAtRiskUsd * (0.9 + rand() * 0.2), 0),
    walletsAtRisk: Math.max(0, base.walletsAtRisk + Math.floor(rand() * 10) - 5),
    badDebtUsd: round(base.badDebtUsd * (0.8 + rand() * 0.4), 2),
  }
  return [
    { slug, day: yesterday, ...prior },
    { slug, day: today, ...base },
  ]
}

const WALLET_EVENT_KINDS = ["supply", "borrow", "repay", "withdraw"] as const

function hex(rand: () => number, length: number): string {
  let out = ""
  while (out.length < length)
    out += Math.floor(rand() * 0xffffffff)
      .toString(16)
      .padStart(8, "0")
  return out.slice(0, length)
}

/** Size of the recurring per-market wallet pool (see walletEventsForMarket). */
const WALLET_POOL_SIZE = 14

/**
 * Deterministic per-market wallet activity over the trailing engagement window.
 * Drives convex/engagement.ts (distinct active wallets/day + the repay/borrow
 * conversion metric).
 *
 * Events are drawn from a small RECURRING wallet pool (not a fresh address per
 * event) so the same wallet emits multiple actions over time — e.g. a `supply`
 * then a `borrow`, or a `borrow` then a `repay`. That recurrence is what makes
 * the conversion KPI (computeConversionPct) a real aggregation instead of 0.
 */
function walletEventsForMarket(slug: string, asOf: number, days: number): SeedWalletEventRow[] {
  const rand = prngFromString(`${slug}:events`)
  const wallets = Array.from({ length: WALLET_POOL_SIZE }, () => `0x${hex(rand, 40)}`)
  const out: SeedWalletEventRow[] = []
  for (let d = days - 1; d >= 0; d--) {
    const dayStart = asOf - d * DAY_MS
    const count = 2 + Math.floor(rand() * 5) // 2–6 events/day
    for (let i = 0; i < count; i++) {
      out.push({
        slug,
        wallet: wallets[Math.floor(rand() * wallets.length)]!,
        kind: WALLET_EVENT_KINDS[Math.floor(rand() * WALLET_EVENT_KINDS.length)]!,
        amountUsd: round(rand() * 50_000, 2),
        // Seeded wallet events are simulated, not real on-chain txs. A "sim-" prefix
        // (instead of 0x) keeps the hash out of the canonical 0x+64hex form so the
        // in-app activity/receipt routing treats it as a sandbox row rather than a
        // dead Etherscan link. Only the prefix changes — the same hex draw is kept so
        // the rest of the deterministic seed (blockNumber/at + later events) is
        // byte-for-byte unchanged.
        txHash: `sim-${hex(rand, 64)}`,
        blockNumber: 19_000_000 + Math.floor(rand() * 1_000_000),
        at: Math.floor(dayStart + rand() * DAY_MS),
      })
    }
  }
  return out
}

/**
 * Convert a computed `RiskAssessment` (from the shared risk-model — the same one
 * the UI mock uses) into the seed row shape. This is why the seeded risk has the
 * full breakdown + metrics instead of an empty stub.
 */
function riskRow(slug: string, assessedAt: number, assessment: RiskAssessment): SeedRiskRow {
  return {
    slug,
    assessedAt,
    premiumBps: assessment.premiumBps,
    level: assessment.level,
    score: assessment.score,
    headline: assessment.headline,
    summary: assessment.summary,
    breakdown: assessment.breakdown,
    metrics: assessment.metrics,
  }
}

/** Build the full deterministic seed for all borrow markets (assets + pools). */
export function buildBorrowSeed(options: BuildSeedOptions = {}): SeedData {
  const days = options.days ?? 365
  // Default to the fixed sandbox clock, not Date.now(): a wall-clock asOf shifts the
  // seeded daily walks every load, which made the /lend "Avg Utilization" (and other
  // seeded metrics) non-deterministic across loads. Callers can still override.
  const asOf = options.asOf ?? SANDBOX_NOW
  const reserveFactor = options.reserveFactor ?? RESERVE_FACTOR_DEFAULT
  const lastDay = isoDay(asOf)

  // Trailing window of wallet activity for the engagement card (covers the 12-day
  // engagement window in convex/engagement.ts with headroom).
  const walletEventDays = Math.min(days, 16)

  const markets: SeedMarketRow[] = []
  const dailyStats: SeedDailyStatRow[] = []
  const borrowDailyStats: SeedBorrowDailyStatRow[] = []
  const lendDailyStats: SeedDailyStatRow[] = []
  const multiplyDailyStats: SeedDailyStatRow[] = []
  const revenue: SeedRevenueRow[] = []
  const borrowRevenueDaily: SeedBorrowRevenueRow[] = []
  const lendRevenueDaily: SeedRevenueRow[] = []
  const multiplyRevenueDaily: SeedRevenueRow[] = []
  const risk: SeedRiskRow[] = []
  const borrowRiskAssessments: SeedBorrowRiskAssessmentRow[] = []
  const lendRiskAssessments: SeedRiskRow[] = []
  const multiplyRiskAssessments: SeedRiskRow[] = []
  const walletEvents: SeedWalletEventRow[] = []
  const allocation: SeedAllocationRow[] = []
  const content: SeedContentRow[] = []
  const borrowMarketContent: SeedBorrowContentRow[] = []
  const lendMarketContent: SeedContentRow[] = []
  const multiplyMarketContent: SeedContentRow[] = []
  const borrowRiskParameters: SeedRiskParameterRow[] = []
  const borrowInterestRateModels: SeedInterestRateModelRow[] = []
  const borrowLiquidationDaily: SeedLiquidationDailyRow[] = []
  const borrowPoolBorrowables: SeedBorrowableEdgeRow[] = []
  const lendRiskParameters: SeedRiskParameterRow[] = []
  const lendInterestRateModels: SeedInterestRateModelRow[] = []
  const multiplyRiskParameters: SeedRiskParameterRow[] = []
  const multiplyLiquidationDaily: SeedLiquidationDailyRow[] = []

  for (const pool of BORROW_POOL_CATALOG) {
    markets.push(poolMarketRow(pool, asOf))
    const utilizationPct =
      pool.tvlUsd > 0 ? Math.min(95, Math.max(5, round((pool.availableUsd / pool.tvlUsd) * 100, 2))) : 45
    const stats = dailyStatsForMarket(
      pool.id,
      "pool",
      { suppliedUsd: pool.tvlUsd, utilizationPct, borrowAprPct: (pool.aprMin + pool.aprMax) / 2 },
      asOf,
      days,
    ).map((row) => ({ ...row, kind: "pool" as const }))
    dailyStats.push(...stats)
    borrowDailyStats.push(...stats)
    const poolRevenue = revenueForMarket(stats, reserveFactor).map((row) => ({ ...row, kind: "pool" as const }))
    revenue.push(...poolRevenue)
    borrowRevenueDaily.push(...poolRevenue)
    risk.push(riskRow(pool.id, asOf, buildPoolRiskAssessment(pool)))
    borrowRiskAssessments.push({ ...risk[risk.length - 1]!, kind: "pool" })
    walletEvents.push(...walletEventsForMarket(pool.id, asOf, walletEventDays))
    const poolAbout = getPoolAboutCard(pool)
    const poolContent = {
      slug: pool.id,
      description: poolAbout.description,
      stats: poolAbout.stats,
      history: poolAbout.history,
      faqs: buildPoolFaqs(pool.name),
    }
    content.push(poolContent)
    borrowMarketContent.push({ ...poolContent, kind: "pool" })
    borrowRiskParameters.push(borrowPoolRiskParameterRow(pool, asOf))
    borrowLiquidationDaily.push(...liquidationDailyForSlug(pool.id, asOf))
    for (const asset of resolveBorrowablesForPool(pool)) {
      borrowPoolBorrowables.push({
        poolSlug: pool.id,
        assetSlug: asset.id,
        name: asset.name,
        symbol: asset.symbol,
        borrowAprPct: asset.apy,
      })
    }
  }

  for (const asset of listSpokeBorrowables()) {
    markets.push(assetMarketRow(asset, asOf))
    const suppliedUsd = asset.availableUsd + asset.totalBorrowedUsd
    const stats = dailyStatsForMarket(
      asset.id,
      "asset",
      { suppliedUsd, utilizationPct: asset.utilization, borrowAprPct: asset.borrowApr },
      asOf,
      days,
    ).map((row) => ({ ...row, kind: "asset" as const }))
    dailyStats.push(...stats)
    borrowDailyStats.push(...stats)
    const assetRevenue = revenueForMarket(stats, reserveFactor).map((row) => ({ ...row, kind: "asset" as const }))
    revenue.push(...assetRevenue)
    borrowRevenueDaily.push(...assetRevenue)
    risk.push(riskRow(asset.id, asOf, buildAssetRiskAssessment(asset)))
    borrowRiskAssessments.push({ ...risk[risk.length - 1]!, kind: "asset" })
    walletEvents.push(...walletEventsForMarket(asset.id, asOf, walletEventDays))
    // Per-pool allocation shares (deterministic, shared with the UI mock). `valueUsd`
    // is filled in below from the CALIBRATED asset TVL so the breakdown sums to the
    // asset's reference value rather than the inflated raw catalog total.
    for (const r of computeAssetAllocationRows(asset)) {
      allocation.push({
        assetSlug: asset.id,
        poolSlug: r.pool.id,
        day: lastDay,
        valueUsd: 0,
        sharePct: r.sharePct,
        utilizationPct: r.utilizationPct,
        borrowAprPct: r.borrowAprPct,
      })
    }
    const assetAbout = getAssetAboutCard(asset)
    const assetContent = {
      slug: asset.id,
      description: assetAbout.description,
      stats: assetAbout.stats,
      history: assetAbout.history,
      faqs: buildAssetFaqs(asset.symbol, asset.name),
    }
    content.push(assetContent)
    borrowMarketContent.push({ ...assetContent, kind: "asset" })
    borrowRiskParameters.push(borrowAssetRiskParameterRow(asset, asOf))
    borrowInterestRateModels.push(interestRateModelRow(asset.id, asset.borrowApr, asOf))
  }

  // Calibrate the latest day to the canonical economy aggregates. `dailyStats` and
  // `revenue` are built in lockstep (same index ↔ same market+day), so a single
  // per-index factor scales both. Utilization/APY are ratios and stay untouched.
  calibrateToTargets(markets, dailyStats, revenue, asOf, {
    poolTvlTargetUsd: options.poolTvlTargetUsd ?? POOL_TVL_TARGET_USD,
    assetTvlTargetUsd: options.assetTvlTargetUsd ?? ASSET_TVL_TARGET_USD,
  })

  // Risk-parameter capacities were built from raw catalog TVLs before calibration.
  // Rewrite them from the calibrated tip so detail Risk Parameters match live size.
  resyncBorrowRiskParameterCapsFromDailyTips(borrowRiskParameters, dailyStats, lastDay)

  // Anchor allocation values to the post-calibration per-asset supplied (latest day)
  // so the asset detail "Value" column reconciles with the headline TVL.
  const suppliedByAsset = new Map<string, number>()
  for (const row of dailyStats) {
    if (row.day === lastDay) suppliedByAsset.set(row.slug, row.suppliedUsd)
  }
  for (const row of allocation) {
    const supplied = suppliedByAsset.get(row.assetSlug) ?? 0
    row.valueUsd = round((supplied * row.sharePct) / 100, 0)
  }

  // Lend markets (single-asset supply). Added AFTER calibration so their catalog-scale
  // USD values aren't rescaled by the borrow economy targets. No pools → no allocation.
  for (const market of LEND_MARKET_CATALOG) {
    markets.push(lendMarketRow(market, asOf))
    const stats = dailyStatsForLendMarket(
      market.marketId,
      {
        suppliedUsd: Math.max(1, market.totalSupplied * market.assetPriceUsd),
        utilizationPct: Math.min(99, Math.max(1, market.utilization * 100)),
        supplyApyPct: Math.max(0.01, market.supplyApy * 100),
        reserveFactor: market.reserveFactor,
        priceUsd: market.assetPriceUsd,
      },
      asOf,
      days,
    )
    dailyStats.push(...stats)
    lendDailyStats.push(...stats)
    const lendRevenue = revenueForMarket(stats, market.reserveFactor)
    revenue.push(...lendRevenue)
    lendRevenueDaily.push(...lendRevenue)
    risk.push(riskRow(market.marketId, asOf, buildLendRiskAssessment(market)))
    lendRiskAssessments.push(risk[risk.length - 1]!)
    walletEvents.push(...walletEventsForMarket(market.marketId, asOf, walletEventDays))
    content.push({
      slug: market.marketId,
      description:
        `${market.asset.name} (${market.asset.symbol}) is a single-asset supply market on Avana. ` +
        `Deposit to earn the supply APY${market.rewardsApy > 0 ? " plus active rewards" : ""}, and withdraw available liquidity anytime. ` +
        `Yield tracks borrower demand, utilization, reserve settings, and market liquidity, so supplier returns can move as deposits and borrows rebalance. ` +
        `The page focuses on the live supply rate, the supply/borrow mix, available liquidity, and the latest risk posture for this ${
          market.riskTier === "low" ? "stablecoin" : "tier-" + market.riskTier
        } market. Suppliers should watch utilization, reserve factor, oracle quality, and withdrawal depth because those inputs affect both earned yield and how quickly capital can exit during stressed conditions.`,
      stats: [
        // Contract addresses injected from lendContractAddresses at Convex overlay time.
      ],
      history: [
        {
          date: market.riskTier === "low" ? "March 18, 2024" : "October 7, 2024",
          title: "Deployed",
          description: "Market contracts deployed.",
        },
        { date: "2025-01-20", title: "Listed", description: `${market.asset.symbol} supply market opened.` },
        {
          date: "2025-09-08",
          title: "Parameters reviewed",
          description: "Quarterly risk review — reserve factor unchanged.",
        },
      ],
      faqs: buildLendFaqs(market.asset.symbol, market.asset.name),
    })
    lendMarketContent.push(content[content.length - 1]!)
    lendRiskParameters.push({
      slug: market.marketId,
      parameters: buildRiskParameterSet({
        collateralFactorPct: market.riskTier === "low" ? 78 : 72,
        liquidationThresholdPct: market.riskTier === "low" ? 83 : 78,
        depositCapacityLabel: formatCompactUsd(
          Math.max(25_000_000, Math.ceil((market.totalSupplied * market.assetPriceUsd * 1.75) / 1_000_000) * 1_000_000),
        ),
        borrowCapacityLabel: formatCompactUsd(
          Math.max(
            10_000_000,
            Math.ceil((market.totalSupplied * market.assetPriceUsd * market.utilization * 2.25) / 1_000_000) *
              1_000_000,
          ),
        ),
        liquidationPenaltyPct: market.riskTier === "low" ? 5 : 7,
        collateralFactorDescription: "Maximum borrow power when this supplied asset is used as collateral.",
      }),
      updatedAt: asOf,
      source: "seed",
    })
    const util = Math.min(99, Math.max(1, market.utilization * 100))
    const supplyApyPct = Math.max(0.01, market.supplyApy * 100)
    const borrowAprPct = supplyApyPct / Math.max(0.05, util / 100) / Math.max(0.5, 1 - market.reserveFactor)
    lendInterestRateModels.push(interestRateModelRow(market.marketId, borrowAprPct, asOf))
  }

  // Multiply markets (leveraged loops). Like lend, appended after calibration so their
  // catalog-scale liquidity isn't rescaled by the borrow economy targets. No pools/allocation.
  for (const market of MULTIPLY_MARKET_CATALOG) {
    markets.push(multiplyMarketRow(market, asOf))
    const utilBase = market.risk.riskTier === "low" ? 68 : market.risk.riskTier === "medium" ? 58 : 48
    const stats = dailyStatsForMultiplyMarket(
      market.id,
      {
        suppliedUsd: Math.max(1, market.economics.availableLiquidityUsd),
        utilizationPct: utilBase,
        supplyApyPct: Math.max(0.01, market.economics.supplyApy * 100),
        borrowAprPct: Math.max(0.01, market.economics.borrowApy * 100),
        priceUsd: market.collateralAsset.priceUsd,
      },
      asOf,
      days,
    )
    dailyStats.push(...stats)
    multiplyDailyStats.push(...stats)
    const multiplyRevenue = revenueForMarket(stats, reserveFactor)
    revenue.push(...multiplyRevenue)
    multiplyRevenueDaily.push(...multiplyRevenue)
    risk.push(riskRow(market.id, asOf, buildMultiplyRiskAssessment(market)))
    multiplyRiskAssessments.push(risk[risk.length - 1]!)
    walletEvents.push(...walletEventsForMarket(market.id, asOf, walletEventDays))
    content.push({
      slug: market.id,
      description: buildMultiplyAboutDescription({
        collateralName: market.collateralAsset.name,
        collateralSymbol: market.collateralAsset.symbol,
        borrowName: market.borrowAsset.name,
        borrowSymbol: market.borrowAsset.symbol,
        maxLeverage: `${market.risk.publicMaxMultiplier.toFixed(2)}x`,
        riskTier: market.risk.riskTier,
      }),
      stats: [
        contractStatForSeed("Vault Contract Address", market.id, "vault"),
        contractStatForSeed("Token Contract Address", market.id, "token"),
        contractStatForSeed("Risk Manager Address", market.id, "riskManager"),
        contractStatForSeed("Oracle Router Address", market.id, "oracleRouter"),
      ],
      history: [
        {
          date: "2025-08-12",
          title: "Market listed",
          description: `${market.collateralAsset.symbol}/${market.borrowAsset.symbol} added to Multiply.`,
        },
        {
          date: "2026-01-18",
          title: "Risk limits refreshed",
          description: "Updated leverage and availability parameters.",
        },
      ],
      faqs: buildMultiplyFaqs(market.collateralAsset.symbol, market.borrowAsset.symbol),
    })
    multiplyMarketContent.push(content[content.length - 1]!)
    multiplyRiskParameters.push({
      slug: market.id,
      parameters: buildRiskParameterSet({
        collateralFactorPct: Math.round(market.risk.collateralFactor * 1000) / 10,
        liquidationThresholdPct: Math.round(market.risk.liquidationThreshold * 1000) / 10,
        depositCapacityLabel: formatCompactUsd(Math.max(25_000_000, market.economics.availableLiquidityUsd * 1.5)),
        borrowCapacityLabel: formatCompactUsd(Math.max(10_000_000, market.economics.availableLiquidityUsd)),
        liquidationPenaltyPct: market.risk.riskTier === "low" ? 5 : 7,
      }),
      updatedAt: asOf,
      source: "seed",
    })
    multiplyLiquidationDaily.push(...liquidationDailyForSlug(market.id, asOf))
  }

  // Governance "Parameter changelog" — generated from each market's FINAL risk parameters
  // (borrow caps are resynced to calibrated tips above), so the newest change of every
  // parameter reconciles with the Risk Parameters grid the detail page renders.
  const parameterChanges = buildParameterChangeRows({
    borrow: borrowRiskParameters,
    lend: lendRiskParameters,
    multiply: multiplyRiskParameters,
    updatedAt: asOf,
  })

  return {
    markets,
    borrowMarkets: markets
      .filter((m): m is SeedMarketRow & { scope: "pool" | "asset" } => m.scope === "pool" || m.scope === "asset")
      // Drop `constituents`: pool rows carry it for the live LP-price recompute on the `markets`
      // table, but the borrowMarkets identity table (and its upsert validator) don't accept it —
      // an extra field there fails the seed insert.
      .map(({ scope, constituents: _constituents, ...rest }) => ({ ...rest, kind: scope })),
    lendMarkets: markets.filter((m) => m.scope === "lend").map(({ scope: _scope, ...rest }) => rest),
    multiplyMarkets: markets.filter((m) => m.scope === "multiply").map(({ scope: _scope, ...rest }) => rest),
    dailyStats,
    borrowDailyStats,
    lendDailyStats,
    multiplyDailyStats,
    revenue,
    borrowRevenueDaily,
    lendRevenueDaily,
    multiplyRevenueDaily,
    risk,
    borrowRiskAssessments,
    lendRiskAssessments,
    multiplyRiskAssessments,
    walletEvents,
    allocation,
    content,
    borrowMarketContent,
    lendMarketContent,
    multiplyMarketContent,
    borrowRiskParameters,
    borrowInterestRateModels,
    borrowLiquidationDaily,
    borrowPoolBorrowables,
    lendRiskParameters,
    lendInterestRateModels,
    multiplyRiskParameters,
    multiplyLiquidationDaily,
    parameterChanges,

    // Phase C additions — pre-derived arrays imported from convex-seed/inputs/.
    // These are pure data (byte-for-byte parity with the mock) and don't
    // interact with the calibration loop above.
    spokes: SPOKES_SEED_ROWS,
    dexes: DEXES_SEED_ROWS,
    borrowAssets: BORROW_ASSETS_SEED_ROWS,
    multiplyInterestRateModels: MULTIPLY_IRM_SEED_ROWS,
    multiplyMarketAllocations: MULTIPLY_ALLOCATION_SEED_ROWS,
    multiplyTokenParameters: MULTIPLY_TOKEN_PARAM_SEED_ROWS,
    poolContractAddresses: POOL_CONTRACT_SEED_ROWS,
    assetContractAddresses: ASSET_CONTRACT_SEED_ROWS,
    lendContractAddresses: LEND_CONTRACT_SEED_ROWS,
    multiplyContractAddresses: MULTIPLY_CONTRACT_SEED_ROWS,
    walletCollateralPositions: TEST_WALLET_COLLATERAL_SEED_ROWS,
    walletDebts: TEST_WALLET_DEBTS_SEED_ROWS,
    walletClaimPositions: TEST_WALLET_CLAIMS_SEED_ROWS,
  }
}

function calibrateToTargets(
  markets: SeedMarketRow[],
  dailyStats: SeedDailyStatRow[],
  revenue: SeedRevenueRow[],
  asOf: number,
  targets: { poolTvlTargetUsd: number; assetTvlTargetUsd: number },
) {
  const lastDay = isoDay(asOf)
  const scopeBySlug = new Map(markets.map((m) => [m.slug, m.scope]))
  let poolLatest = 0
  let assetLatest = 0
  for (const row of dailyStats) {
    if (row.day !== lastDay) continue
    if (scopeBySlug.get(row.slug) === "pool") poolLatest += row.suppliedUsd
    else assetLatest += row.suppliedUsd
  }
  const poolFactor = poolLatest > 0 ? targets.poolTvlTargetUsd / poolLatest : 1
  const assetFactor = assetLatest > 0 ? targets.assetTvlTargetUsd / assetLatest : 1

  for (let i = 0; i < dailyStats.length; i++) {
    const stat = dailyStats[i]!
    const f = scopeBySlug.get(stat.slug) === "pool" ? poolFactor : assetFactor
    stat.suppliedUsd = round(stat.suppliedUsd * f, 0)
    stat.borrowedUsd = round(stat.borrowedUsd * f, 0)
    stat.tvlUsd = round(stat.tvlUsd * f, 0)
    stat.volumeUsd = round(stat.volumeUsd * f, 0)
    stat.feesUsd = round(stat.feesUsd * f, 2)
    const rev = revenue[i]
    if (rev) {
      rev.interestFromBorrowersUsd = round(rev.interestFromBorrowersUsd * f, 2)
      rev.interestToSuppliersUsd = round(rev.interestToSuppliersUsd * f, 2)
      rev.reserveTakeUsd = round(rev.reserveTakeUsd * f, 2)
      rev.rewardsDistributedUsd = round(rev.rewardsDistributedUsd * f, 2)
      rev.swapFeesUsd = round(rev.swapFeesUsd * f, 2)
    }
  }
}
