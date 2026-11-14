/**
 * Mock `PoolDetail` factory: hand-curated fixtures for the three home-page pools
 * (`eth-usdc`, `wbtc-eth`, `usdc-usdt`) plus a procedural fallback for every other
 * catalog id. Series come from the seeded PRNG so charts stay stable.
 *
 * To go live, replace the `buildPoolDetail` call in `index.ts` with a fetch.
 */

import {
  type BorrowAssetVisual,
  type BorrowPoolRow,
  formatCompactUsd,
  getDexById,
  getSpokeById,
} from "@/app/lib/borrow-sim"
import { liquidationThresholdPctFromMaxLtvPct } from "@/app/lib/borrow-system/liquidation-threshold"
import { buildSeriesFamily, prngFromString } from "./prng"
import { formatBpsAsPct, formatPct } from "./allocation"
import { formatPairRate } from "./formatters"
import { sandboxBaselinePriceUsd } from "@/app/lib/prices/sandbox-baseline-prices"
import { buildPoolRiskAssessment } from "./risk-model"
import { buildPoolFaqs } from "./content-model"
import { getRegistryToken } from "@/app/lib/tokens/registry"
import { buildPoolProtocolParameters } from "./protocol-parameters"
import { buildRiskParameterSet } from "./risk-parameters"
import { resolveHeroContractAddress } from "@/app/borrow/_detail/lib/hero-chart-feeds"
import type {
  AboutCard,
  CashflowCard,
  ChartMetricId,
  DeltaStat,
  PoolDetail,
  PoolDetailHero,
  QuickStat,
  RiskAssessment,
  Series,
  TimeRangeId,
  TxHistoryRow,
} from "./types"

// -------------------------------------------------------------------------
// Home-page id → catalog mapping
// -------------------------------------------------------------------------

/** Maps the compact ids we use on the home page to a real catalog row. */
const HOME_ID_TO_CATALOG_ID: Record<string, string> = {
  "eth-usdc": "uni-v3-bluechip-weth-usdc",
  "wbtc-eth": "uni-v3-bluechip-wbtc-weth",
  "usdc-usdt": "uni-v3-stable-usdc-usdt",
}

// -------------------------------------------------------------------------
// Hand-curated fixture overrides
// -------------------------------------------------------------------------

type FixtureOverride = {
  /** Human-readable chain tag shown next to the header. */
  chain?: string
  /** Fee tier label, e.g. "0.3%" / "Stable". */
  feeTier?: string
  /** Explorer URL for the source pool (only used in the hero). */
  explorerUrl?: string
  /** Quick-stat overrides, merged over defaults by id. */
  quickStats?: Record<string, Partial<QuickStat>>
  /** Base TVL used by hero + key metrics (overrides catalog liquidity). */
  baseTvlUsd?: number
  /** Daily volume used to seed cashflow / key-metric charts (overrides derived). */
  baseVolumeUsd?: number
  /** Daily fees used to seed cashflow / key-metric charts (overrides derived). */
  baseFeesUsd?: number
  /** About card override (description + stats + history). */
  about?: AboutCard
  /** Risk assessment override for curated pools. */
  risk?: RiskAssessment
  /** Description line shown under the hero title. */
  subtitle?: string
}

const CURATED_FIXTURES: Record<string, FixtureOverride> = {
  "uni-v3-bluechip-weth-usdc": {
    chain: "Ethereum",
    feeTier: "0.30%",
    explorerUrl: "https://app.uniswap.org/explore/pools/ethereum/0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640",
    subtitle: "Concentrated-liquidity ETH/USDC exposure accepted as LP collateral for borrowing.",
    baseTvlUsd: 312_400_000,
    baseVolumeUsd: 48_900_000,
    baseFeesUsd: 146_700,
    quickStats: {
      totalSupplied: { value: "$312.4M", delta: deltaUp(2.4) },
      totalBorrowed: { value: "$48.9M", delta: deltaUp(6.1) },
      riskPremium: { value: formatBpsAsPct(70), delta: deltaUp(6.1) },
      utilization: { value: "62.1%", delta: deltaDown(1.3) },
    },
    about: {
      description:
        "ETH/USDC 0.30% is the deepest Uniswap v3 pool by volume and functions as the benchmark pair for ETH price discovery. The Bluechip spoke accepts these LP positions as borrow collateral, which means this market sits at the intersection of deep trading liquidity, a stable quote asset, and a higher-risk volatile leg. The combination gives borrowers meaningful capacity while still keeping the underwriting rules conservative enough to absorb ETH drawdowns.",
      stats: [],
      history: [
        { date: "2024-05-07", title: "Spoke launched", description: "Uni v3 Bluechip added as collateral source." },
        {
          date: "2024-11-19",
          title: "LTV raised to 70%",
          description: "Risk council bumped the ceiling from 65% to 70%.",
        },
        { date: "2025-08-02", title: "Oracle window shortened", description: "Switched from 60m to 30m TWAP." },
      ],
    },
    risk: {
      premiumBps: 70,
      level: "moderate",
      score: 38,
      headline: "Moderate risk · +0.70% premium",
      summary:
        "ETH/USDC on Uniswap v3 is deep and battle-tested but exposes LPs to ETH volatility. Risk is dominated by impermanent loss and, to a lesser degree, oracle latency during fast moves.",
      breakdown: [
        {
          id: "vol",
          label: "ETH volatility",
          bps: 32,
          level: "moderate",
          description: "30d realized σ ≈ 58% annualized — the single biggest contributor to impermanent loss.",
        },
        {
          id: "depth",
          label: "Liquidity depth",
          bps: 8,
          level: "low",
          description: "$4.1M of 2% depth across all tiers — ample for liquidations.",
        },
        {
          id: "oracle",
          label: "Oracle latency",
          bps: 18,
          level: "moderate",
          description: "30-minute TWAP can lag during sharp moves; mitigated by kink in the risk curve.",
        },
        {
          id: "smart-contract",
          label: "Smart-contract surface",
          bps: 8,
          level: "low",
          description: "Uniswap v3 core + NonFungiblePositionManager, both heavily audited and live for 4 years.",
        },
        {
          id: "il",
          label: "Expected IL",
          bps: 4,
          level: "low",
          description: "Rolling 90d IL averages 23bps per week for the 0.30% tier.",
        },
      ],
      metrics: [
        { id: "sigma", label: "σ 30d (annualized)", value: "58.4%" },
        { id: "depth", label: "2% depth", value: "$4.1M" },
        { id: "il", label: "Weekly IL (avg)", value: "0.23%" },
        { id: "corr", label: "Dependencies", value: "Uniswap v3, Chainlink ETH" },
      ],
      lastReviewed: "2026-03-11",
    },
  },
  "uni-v3-bluechip-wbtc-weth": {
    chain: "Ethereum",
    feeTier: "0.30%",
    explorerUrl: "https://app.uniswap.org/explore/pools/ethereum/0xCBCdF9626bC03E24f779434178A73a0B4bad62eD",
    subtitle: "WBTC/WETH LP positions accepted as collateral in the Bluechip spoke.",
    baseTvlUsd: 148_300_000,
    baseVolumeUsd: 18_200_000,
    baseFeesUsd: 54_600,
    quickStats: {
      totalSupplied: { value: "$148.3M", delta: deltaUp(1.1) },
      totalBorrowed: { value: "$18.2M", delta: deltaUp(3.8) },
      riskPremium: { value: formatBpsAsPct(85), delta: deltaUp(3.8) },
      utilization: { value: "48.3%", delta: deltaDown(0.4) },
    },
    about: {
      description:
        "WBTC/WETH is the dominant on-chain BTC↔ETH trading pair and one of the most familiar blue-chip routes in DeFi. The Bluechip spoke allows it as collateral with a conservative 67% LTV because bridged-BTC custody risk, even when well managed, still deserves a tighter margin than native ETH pairs. That keeps borrowing power useful without treating wrapped BTC like a pure base-asset market.",
      stats: [],
      history: [
        { date: "2024-07-22", title: "Pool onboarded", description: "WBTC/WETH added to the Bluechip spoke." },
        {
          date: "2025-02-14",
          title: "Dual-oracle",
          description: "Added Chainlink feed alongside the TWAP for resilience.",
        },
      ],
    },
    risk: {
      premiumBps: 85,
      level: "moderate",
      score: 44,
      headline: "Moderate risk · +0.85% premium",
      summary:
        "WBTC carries BitGo custody risk on top of BTC volatility. The pair's depth is comfortable and the dual-oracle setup mitigates single-feed failure modes.",
      breakdown: [
        {
          id: "vol",
          label: "BTC volatility",
          bps: 28,
          level: "moderate",
          description: "30d realized σ ≈ 48% annualized.",
        },
        {
          id: "custody",
          label: "WBTC custody",
          bps: 30,
          level: "elevated",
          description: "WBTC depends on BitGo custody — reviewed monthly by the risk council.",
        },
        {
          id: "oracle",
          label: "Oracle",
          bps: 14,
          level: "low",
          description: "Chainlink feed + 30m TWAP with deviation guardrails.",
        },
        { id: "depth", label: "Liquidity depth", bps: 8, level: "low", description: "$2.6M of 2% depth." },
        {
          id: "il",
          label: "Expected IL",
          bps: 5,
          level: "low",
          description: "BTC/ETH is highly correlated — IL is usually <15bps/week.",
        },
      ],
      metrics: [
        { id: "sigma", label: "σ 30d (annualized)", value: "48.1%" },
        { id: "depth", label: "2% depth", value: "$2.6M" },
        { id: "corr", label: "BTC↔ETH 30d ρ", value: "0.81" },
        { id: "deps", label: "Dependencies", value: "BitGo, Chainlink" },
      ],
      lastReviewed: "2026-03-11",
    },
  },
  "uni-v2-weth-dai": {
    chain: "Ethereum",
    feeTier: "0.30%",
    subtitle: "WETH/DAI LP positions accepted as collateral in the Uniswap v2 spoke.",
    about: {
      description:
        "WETH/DAI is a standard Uniswap v2 ETH/stable pair and a straightforward LP structure for collateral evaluation. The Uniswap v2 spoke admits it under conservative parameters because the pair still carries ETH volatility, while the stable quote side keeps the market easy to reason about.",
      stats: [],
      history: [
        { date: "2025-01-14", title: "Onboarded", description: "Added to the Uniswap v2 LPs." },
        {
          date: "2025-06-02",
          title: "Parameters refreshed",
          description: "Quarterly risk review — no changes to LTV.",
        },
      ],
      news: [
        {
          time: "2025-01-14",
          title: "Onboarded",
          description: "Added to the Uniswap v2 LPs.",
          source: "Latest update",
        },
        {
          time: "2025-06-02",
          title: "Parameters refreshed",
          description: "Quarterly risk review — no changes to LTV.",
          source: "Protocol note",
        },
      ],
    },
  },
  "uni-v3-stable-usdc-usdt": {
    chain: "Ethereum",
    feeTier: "0.01%",
    explorerUrl: "https://app.uniswap.org/explore/pools/ethereum/0x3416cF6C708Da44DB2624D63ea0AAef7113527C6",
    subtitle: "Full-range USDC/USDT liquidity accepted in the Stable spoke at up to 78% LTV.",
    baseTvlUsd: 198_600_000,
    baseVolumeUsd: 22_100_000,
    baseFeesUsd: 2_210,
    quickStats: {
      totalSupplied: { value: "$198.6M", delta: deltaUp(0.4) },
      totalBorrowed: { value: "$22.1M", delta: deltaUp(1.9) },
      riskPremium: { value: formatBpsAsPct(25), delta: deltaUp(1.9) },
      utilization: { value: "71.4%", delta: deltaUp(0.8) },
    },
    about: {
      description:
        "USDC and USDT both trade at parity and the pool is overwhelmingly used for order-routing, stability-seeking flow, and tight-spread execution. The Stable spoke admits it with a high LTV because peg-risk is shared, depth is enormous, and the pool behaves more like cash infrastructure than a typical volatile LP. That makes it a natural fit for users who want borrowing power while keeping the underlying collateral profile simple to reason about.",
      stats: [],
      history: [
        { date: "2024-04-15", title: "Stable spoke launch", description: "USDC/USDT included from day 1." },
        {
          date: "2025-03-09",
          title: "De-peg drill",
          description: "Circuit-breaker simulated during USDC March 2023 re-run — no forced liquidations.",
        },
      ],
    },
    risk: {
      premiumBps: 25,
      level: "low",
      score: 14,
      headline: "Low risk · +0.25% premium",
      summary:
        "Peg-to-peg correlation keeps impermanent loss negligible. The only tail scenarios involve a USDC or USDT de-peg; both are paused automatically by our oracle deviation guard.",
      breakdown: [
        {
          id: "depeg",
          label: "De-peg tail",
          bps: 12,
          level: "low",
          description: "Guardrails pause new borrows if the Chainlink feed deviates >50bps for 5m.",
        },
        {
          id: "issuer",
          label: "Issuer solvency",
          bps: 6,
          level: "low",
          description: "Circle + Tether attestations ingested weekly.",
        },
        { id: "depth", label: "Liquidity depth", bps: 2, level: "low", description: "$18M of 2% depth." },
        { id: "sc", label: "Smart-contract surface", bps: 3, level: "low", description: "Uniswap v3 + LP NFT only." },
        {
          id: "il",
          label: "Expected IL",
          bps: 2,
          level: "low",
          description: "Correlated assets → IL near zero in normal conditions.",
        },
      ],
      metrics: [
        { id: "sigma", label: "σ 30d (annualized)", value: "1.4%" },
        { id: "depth", label: "2% depth", value: "$18M" },
        { id: "deps", label: "Dependencies", value: "Circle, Tether" },
        { id: "corr", label: "USDC↔USDT 30d ρ", value: "0.99" },
      ],
      lastReviewed: "2026-03-18",
    },
  },
}

// -------------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------------

function deltaUp(pct: number): DeltaStat {
  return { value: pct, direction: "up", label: `+${pct.toFixed(1)}%` }
}

function deltaDown(pct: number): DeltaStat {
  return { value: -Math.abs(pct), direction: "down", label: `-${Math.abs(pct).toFixed(1)}%` }
}

function pickChain(row: BorrowPoolRow): string {
  const venue = row.venue.toLowerCase()
  if (venue.includes("aerodrome") || venue.includes("base")) return "Base"
  if (venue.includes("arbitrum")) return "Arbitrum"
  if (venue.includes("optimism")) return "Optimism"
  return "Ethereum"
}

function isStablePool(row: BorrowPoolRow) {
  const stables = new Set(["USDC", "USDT", "DAI", "GHO", "FRAX", "CRVUSD", "USDS"])
  return row.visuals.every((visual) => stables.has(visual.symbol.toUpperCase()))
}

function buildDefaultQuickStats(row: BorrowPoolRow): QuickStat[] {
  const supplyApy = (row.aprMin + row.aprMax) / 2
  return [
    {
      id: "price",
      label: "Price",
      value: `${formatPairRate(pairReferencePrice(row))} ${row.visuals[1]?.symbol ?? "USDC"}`,
      delta: deltaUp(0.1),
    },
    {
      id: "available",
      label: "Available Liquidity",
      value: formatCompactUsd(row.availableUsd),
      delta: deltaUp(0.6),
    },
    // The LP's trading-fee APR; the Borrow list and Explore cards call it "LP APR".
    { id: "supplyApy", label: "LP APR", value: formatPct(supplyApy, 2), delta: deltaUp(0.1) },
    { id: "rewardsApy", label: "Rewards APY", value: "No rewards" },
    // Borrow APY is Convex-sourced — the mock never has enough to derive a real value
    // (it would have to know the pool's utilization + reserve factor + constituent asset
    // borrow rates). getQuickStats emits `borrowApy` from Convex's implied rate;
    // mergeConvexQuickStats replaces this placeholder. Live-mode without a snapshot
    // fails closed via shouldFailClosedWithoutSnapshots — never shows the em dash to a user.
    { id: "borrowApy", label: "Borrow APR", value: "—" },
    { id: "reserveFactor", label: "Reserve Factor", value: isStablePool(row) ? "10%" : "15%" },
  ]
}

function mergeQuickStats(defaults: QuickStat[], overrides?: FixtureOverride["quickStats"]): QuickStat[] {
  if (!overrides) return defaults
  return defaults.map((stat) => ({ ...stat, ...(overrides[stat.id] ?? {}) }))
}

function buildHero(row: BorrowPoolRow, fixture: FixtureOverride | undefined): PoolDetailHero {
  const venue = row.venue
  const visuals: [BorrowAssetVisual, BorrowAssetVisual] = row.visuals
  return {
    visuals,
    name: row.name,
    venue,
    // Concise market-type label, e.g. "Uniswap v3 Blue-Chip LPs".
    marketLabel: getSpokeById(row.spoke).label,
    subtitle: fixture?.subtitle ?? `${row.name} accepted as LP collateral. Supply to unlock borrow power.`,
    feeTier: fixture?.feeTier,
    chain: fixture?.chain ?? pickChain(row),
    explorerUrl: fixture?.explorerUrl ?? `https://etherscan.io/address/${resolveHeroContractAddress(row.id)}`,
  }
}

function buildHeroMetricSeries(
  row: BorrowPoolRow,
  fixture: FixtureOverride | undefined,
): Record<ChartMetricId, Record<TimeRangeId, Series>> {
  // Use the pool row's own TVL/available (Convex-hydrated when live), NEVER spoke.liquidityUsd.
  // spoke.liquidityUsd is catalog-scale (~$1.25B for uni-v3-stable) and produced absurd
  // "Borrowed" hero headlines (~$1.2B) next to Convex Supplied (~$63M).
  const baseTvl = fixture?.baseTvlUsd ?? Math.max(1, row.tvlUsd)
  const baseBorrowed = Math.max(1, Math.round(baseTvl - Math.min(row.availableUsd, baseTvl)))
  const baseUtilization = Math.max(1, Math.min(95, (baseBorrowed / Math.max(1, baseTvl)) * 100))
  return {
    // Supplied/TVL is a level — keep the series close to the stated base so the hero
    // headline reconciles with Key Statistics instead of ending materially higher/lower.
    tvl: buildSeriesFamily(`${row.id}:tvl`, "Supplied", {
      base: baseTvl,
      driftMultiplier: 1.0,
      noise: 0.02,
      wave: 0.04,
      nonNegative: true,
      roundTo: 0,
    }),
    borrowed: buildSeriesFamily(`${row.id}:borrowed`, "Borrowed", {
      base: baseBorrowed,
      driftMultiplier: 1.06,
      noise: 0.04,
      wave: 0.06,
      nonNegative: true,
      roundTo: 0,
    }),
    utilization: buildSeriesFamily(`${row.id}:utilization`, "Utilization", {
      base: baseUtilization,
      driftMultiplier: 1.02,
      noise: 0.05,
      wave: 0.08,
      nonNegative: true,
      roundTo: 2,
    }),
  }
}

function pairReferencePrice(row: BorrowPoolRow): number {
  // The pool "Price" stat is the pair spot rate — the base leg priced in the quote leg (the live
  // path shows P(base) ÷ P(quote), the caller appends the quote symbol). Mirror that here so the
  // deterministic fallback matches, e.g. cbBTC/WETH → ~33.7 (WETH per cbBTC), not a "$" value.
  const base = row.visuals[0]?.symbol ?? "USDC"
  const quote = row.visuals[1]?.symbol ?? "USDC"
  const quotePrice = sandboxBaselinePriceUsd(quote)
  return quotePrice > 0 ? sandboxBaselinePriceUsd(base) / quotePrice : 0
}

function buildCashflow(row: BorrowPoolRow, fixture: FixtureOverride | undefined): CashflowCard {
  const tvl = fixture?.baseTvlUsd ?? getSpokeById(row.spoke).liquidityUsd
  const vol = fixture?.baseVolumeUsd ?? Math.round(tvl * 0.12)
  const fees = fixture?.baseFeesUsd ?? Math.round(vol * 0.003)
  const feesSeries = buildSeriesFamily(`${row.id}:cashflow:fees`, "Fees", {
    base: fees * 30,
    driftMultiplier: 1.04,
    noise: 0.1,
    nonNegative: true,
    roundTo: 0,
  })["1Y"]
  const incentivesSeries = buildSeriesFamily(`${row.id}:cashflow:incentives`, "Incentives", {
    base: fees * 12,
    driftMultiplier: 1.06,
    noise: 0.2,
    nonNegative: true,
    roundTo: 0,
  })["1Y"]
  return {
    bars: [feesSeries, incentivesSeries],
    periodLabel: "Last 12 months",
    rows: [
      {
        label: "Swap fees",
        reported: formatCompactUsd(fees * 365 * 0.78),
        yoy: { value: 12.4, direction: "up", label: "+12.4%" },
        highlighted: true,
      },
      {
        label: "LP incentives",
        reported: formatCompactUsd(fees * 365 * 0.18),
        yoy: { value: 8.1, direction: "up", label: "+8.1%" },
      },
      {
        label: "Protocol revenue",
        reported: formatCompactUsd(fees * 365 * 0.04),
        yoy: { value: -1.1, direction: "down", label: "-1.1%" },
      },
      {
        label: "Rewards emitted",
        reported: formatCompactUsd(fees * 365 * 0.12),
        yoy: { value: 2.8, direction: "up", label: "+2.8%" },
      },
      {
        label: "Net to suppliers",
        reported: formatCompactUsd(fees * 365 * 0.9),
        yoy: { value: 10.2, direction: "up", label: "+10.2%" },
        highlighted: true,
      },
    ],
  }
}

function buildRisk(row: BorrowPoolRow, fixture: FixtureOverride | undefined): RiskAssessment {
  if (fixture?.risk) return fixture.risk
  // Single source of truth shared with the Convex seed (build-seed.ts).
  return buildPoolRiskAssessment(row)
}

function buildPoolGovernanceParameters(row: BorrowPoolRow): NonNullable<AboutCard["governanceParameters"]> {
  const ltvPct = row.ltv
  const liquidationThresholdPct = Math.round(liquidationThresholdPctFromMaxLtvPct(row.ltv) * 10) / 10
  const liquidationBonusPct = isStablePool(row) ? 5 : 7
  const suppliedUsd = getSpokeById(row.spoke).liquidityUsd
  const supplyCapUsd = Math.max(25_000_000, Math.ceil((suppliedUsd * 1.75) / 1_000_000) * 1_000_000)
  const borrowCapUsd = Math.max(10_000_000, Math.ceil((row.availableUsd * 2.25) / 1_000_000) * 1_000_000)
  const reserve = isStablePool(row) ? 10 : 15

  return {
    parameters: buildRiskParameterSet({
      collateralFactorPct: ltvPct,
      liquidationThresholdPct,
      depositCapacityLabel: formatCompactUsd(supplyCapUsd),
      borrowCapacityLabel: formatCompactUsd(borrowCapUsd),
      liquidationPenaltyPct: liquidationBonusPct,
      collateralFactorDescription: "Maximum borrow power when this LP position is used as collateral.",
    }),
    changelog: [
      {
        id: "supply-cap-review",
        parameter: "Deposit capacity",
        previous: formatCompactUsd(Math.round(supplyCapUsd * 0.86)),
        current: formatCompactUsd(supplyCapUsd),
        date: "2025-09-08",
        source: "Risk parameter review",
        executor: "Governance executor",
        // Governance proposal link removed with contractAddressFor — the convex overlay
        // (governanceParameters.changelog is currently untouched by convex-detail; a
        // later pass can inject the real proposal href from the Convex governance row).
      },
      {
        id: "reserve-factor-review",
        parameter: "Reserve factor",
        previous: `${Math.max(0, reserve - 1)}%`,
        current: `${reserve}%`,
        date: "2025-06-02",
        source: "Revenue parameter update",
        executor: "Risk steward multisig",
        // Governance proposal link removed with contractAddressFor — the convex overlay
        // (governanceParameters.changelog is currently untouched by convex-detail; a
        // later pass can inject the real proposal href from the Convex governance row).
      },
      {
        id: "collateral-onboarding",
        parameter: "Collateral configuration",
        previous: "Disabled",
        current: `${formatPct(ltvPct, 1)} CF / ${formatPct(liquidationThresholdPct, 1)} LT`,
        date: "2025-01-20",
        source: "Market onboarding",
        executor: "Governance executor",
        // Governance proposal link removed with contractAddressFor — the convex overlay
        // (governanceParameters.changelog is currently untouched by convex-detail; a
        // later pass can inject the real proposal href from the Convex governance row).
      },
    ],
  }
}

const STOCK_SPOKE_IDS = new Set<string>(["aero-concentrated-stocks", "uni-robinhood-stocks"])

/** The tokenized-equity leg of a stock pool (e.g. NVDAc), with its underlying company name. */
function stockLegOf(row: BorrowPoolRow): { symbol: string; name: string } | null {
  for (const visual of row.visuals) {
    const token = getRegistryToken(visual.symbol)
    if (token && (token.priceSource === "stock" || token.priceSource === "fixture")) {
      return { symbol: token.displaySymbol ?? token.symbol, name: token.name }
    }
  }
  return null
}

/** About copy: a tokenized-equity variant for the stock spokes, else the generic LP-collateral copy. */
function describePool(row: BorrowPoolRow, spoke: ReturnType<typeof getSpokeById>): string {
  const venueLabel = getDexById(row.dexes[0]?.id as Parameters<typeof getDexById>[0])?.label ?? row.venue
  const stock = STOCK_SPOKE_IDS.has(row.spoke) ? stockLegOf(row) : null
  if (stock) {
    const stableLeg = row.visuals.map((visual) => visual.symbol).find((symbol) => symbol !== stock.symbol) ?? "USDC"
    return (
      `${row.name} is a tokenized-equity LP position posted as collateral inside the ${spoke.label} spoke on Avana. ` +
      `It pairs ${stableLeg} with tokenized ${stock.name} (${stock.symbol}) exposure, so collateral value tracks the ${stock.name} share price alongside the pool's depth and fee tier. ` +
      `Avana anchors borrow power to the spoke's max LTV, keeping credit tied to how sharply tokenized-equity collateral can move. ` +
      `This page is the single source of truth for what the pool is, how much capital it can safely support, and the downside the protocol underwrites.`
    )
  }
  return (
    `${row.name} on ${venueLabel} is treated as LP collateral inside the ${spoke.label}. ` +
    `The pool's depth, fee tier, and pair composition determine how much it can support, while the spoke's max LTV keeps the borrow power anchored to the market's actual risk. ` +
    `That gives this page a single source of truth for how the pool should be understood: what it is, how much capital it can safely support, and what kind of downside the protocol is underwriting.`
  )
}

function buildAbout(row: BorrowPoolRow, fixture: FixtureOverride | undefined): AboutCard {
  const spoke = getSpokeById(row.spoke)
  const about = fixture?.about ?? {
    description: describePool(row, spoke),
    stats: [],
    history: [
      { date: "2025-01-14", title: "Onboarded", description: `Added to the ${spoke.label}.` },
      { date: "2025-06-02", title: "Parameters refreshed", description: "Quarterly risk review — no changes to LTV." },
    ],
  }

  // Contract-address stats now injected at overlay time by getPoolDetailFromConvex via
  // api.contractAddresses.listPoolAddresses. The FNV-hashed synthetic addresses that
  // used to seed this array have been superseded by the Convex table (same values on
  // disk today, but a single source instead of two).
  return {
    ...about,
    stats: [],
    governanceParameters: buildPoolGovernanceParameters(row),
  }
}

function buildCollateralHistory(row: BorrowPoolRow): TxHistoryRow[] {
  const seed = prngFromString(`${row.id}:tx`)
  const kinds: TxHistoryRow["kind"][] = ["supply", "withdraw", "rewards"]
  const out: TxHistoryRow[] = []
  const now = Date.now()
  const token0Symbol = row.visuals[0].symbol.toUpperCase()
  const token1Symbol = row.visuals[1].symbol.toUpperCase()
  const token0Usd = token0Symbol.includes("BTC") ? 68_400 : token0Symbol.includes("ETH") ? 3_450 : 1
  const token1Usd = token1Symbol.includes("BTC") ? 68_400 : token1Symbol.includes("ETH") ? 3_450 : 1

  for (let i = 0; i < 12; i++) {
    const kind = kinds[i % kinds.length]
    const amountBase = kind === "rewards" ? 250 + seed() * 15_000 : 50_000 + seed() * 1_950_000
    const amount = Math.round(amountBase / 100) * 100
    const ageMs = i * 30_000 + Math.floor(seed() * 5_000)
    const at = new Date(now - ageMs).toISOString()
    const prefix = kind === "withdraw" ? "-" : "+"
    const walletAddress = `0x${Math.floor(seed() * 0xffffffff)
      .toString(16)
      .padStart(8, "0")}${Math.floor(seed() * 0xffffffff)
      .toString(16)
      .padStart(8, "0")}${Math.floor(seed() * 0xffffffff)
      .toString(16)
      .padStart(8, "0")}${Math.floor(seed() * 0xffffffff)
      .toString(16)
      .padStart(8, "0")}${Math.floor(seed() * 0xffffffff)
      .toString(16)
      .padStart(8, "0")}`
    const walletLabel = `${walletAddress.slice(0, 6)}...${walletAddress.slice(-4)}`
    const token0Share = kind === "rewards" ? 0 : 0.48 + seed() * 0.14
    const token1Share = 1 - token0Share
    const token0Amount = (amount * token0Share) / token0Usd
    const token1Amount = (amount * token1Share) / token1Usd
    out.push({
      id: `${row.id}-tx-${i}`,
      at,
      timeLabel: formatRelativeAge(ageMs),
      kind,
      amountLabel: `${prefix}${formatCompactUsd(amount)}`,
      token0AmountLabel: kind === "rewards" ? "—" : formatTokenAmount(token0Amount),
      token1AmountLabel: kind === "rewards" ? "—" : formatTokenAmount(token1Amount),
      tokenSymbol: token0Symbol,
      tokenSymbolSecondary: token1Symbol,
      tokenAmountLabel:
        kind === "rewards" ? undefined : `${formatTokenAmount(token0Amount)} / ${formatTokenAmount(token1Amount)}`,
      counterpartyLabel: undefined,
      walletLabel,
      walletHref: `https://etherscan.io/address/${walletAddress}`,
      txHashShort: `0x${Math.floor(seed() * 0xffffff)
        .toString(16)
        .padStart(6, "0")}…${Math.floor(seed() * 0xffff)
        .toString(16)
        .padStart(4, "0")}`,
    })
  }

  return out
}

function formatRelativeAge(ageMs: number) {
  const totalSeconds = Math.max(1, Math.floor(ageMs / 1000))
  if (totalSeconds < 60) return `${totalSeconds}s`
  const totalMinutes = Math.floor(totalSeconds / 60)
  return `${totalMinutes}m`
}

function formatTokenAmount(value: number) {
  if (value >= 1_000) return value.toLocaleString(undefined, { maximumFractionDigits: 2 })
  if (value >= 1) return value.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 5 })
  if (value >= 0.01) return value.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 5 })
  return value.toLocaleString(undefined, { minimumFractionDigits: 4, maximumFractionDigits: 6 })
}

// -------------------------------------------------------------------------
// Public API
// -------------------------------------------------------------------------

export function buildPoolDetail(row: BorrowPoolRow): PoolDetail {
  const fixture = CURATED_FIXTURES[row.id]
  const heroMetricSeries = buildHeroMetricSeries(row, fixture)
  const baseTvl = fixture?.baseTvlUsd ?? Math.max(1, row.tvlUsd)
  return {
    id: row.id,
    hero: buildHero(row, fixture),
    heroMetric: {
      metricId: "tvl",
      valueLabel: fixture?.quickStats?.tvl?.value ?? formatCompactUsd(baseTvl),
      delta: fixture?.quickStats?.tvl?.delta ?? deltaUp(2.1),
      series: heroMetricSeries,
    },
    quickStats: mergeQuickStats(buildDefaultQuickStats(row), fixture?.quickStats),
    protocolParameters: buildPoolProtocolParameters(row),
    cashflow: buildCashflow(row, fixture),
    risk: buildRisk(row, fixture),
    about: buildAbout(row, fixture),
    faqs: buildPoolFaqs(row.name),
    transactions: buildCollateralHistory(row),
    row,
  }
}

/** About card for seeding the Convex content layer (mirrors what the detail page renders). */
export function getPoolAboutCard(row: BorrowPoolRow): AboutCard {
  return buildAbout(row, CURATED_FIXTURES[row.id])
}

/** Exposed so the app can enumerate home-page → detail-page ids in tests. */
export const HOME_POOL_ID_MAP = HOME_ID_TO_CATALOG_ID
