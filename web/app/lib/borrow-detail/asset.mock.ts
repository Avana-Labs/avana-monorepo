/**
 * Mock `AssetDetail` factory. Mirrors pool.mock.ts but for borrowable assets.
 *
 * - Hand-curated overrides for USDC / ETH / WBTC (the three likely demos).
 * - Procedural fallback for every other spoke-bound borrowable product.
 * - Allocation rows come from `allocation.ts::computeAssetAllocation`.
 *
 * Swap `buildAssetDetail` for a live fetch in `index.ts` when ready.
 */

import { BORROW_POOL_CATALOG, formatCompactUsd } from "@/app/lib/borrow-sim"
import { resolveSpokeBorrowable, type SpokeBorrowableRecord } from "@/app/lib/borrow-system/registry"
import { formatDetailTokenAmount } from "@/app/lib/detail-page/transaction-display"
import { buildSeries, buildSeriesFamily, prngFromString } from "./prng"
import { SANDBOX_NOW } from "@/app/lib/deterministic"
import { anchorPriceFamilyToCanonical, buildCuratedPriceFamily } from "./token-price-series"
import { canonicalPriceUsd } from "@/app/lib/prices/canonical"
import { computeAssetAllocation } from "./allocation"
import { buildAssetRiskAssessment } from "./risk-model"
import { buildAssetProtocolParameters } from "./protocol-parameters"
import { buildAssetFaqs } from "./content-model"
import { buildRiskParameterSet } from "./risk-parameters"
import type {
  AboutCard,
  AllocationRow,
  AssetChartMetricId,
  AssetDetail,
  AssetDetailHero,
  CashflowCard,
  CashflowTrend,
  DeltaStat,
  PerfPeriod,
  PerfTabDataset,
  QuickStat,
  RiskAssessment,
  Series,
  TimeRangeId,
  TxHistoryRow,
} from "./types"
import { ALL_ASSET_CHART_METRICS, ALL_PERF_PERIODS } from "./types"

type AssetFixture = {
  chain?: string
  heroPriceUsd?: number
  heroPriceChangePct?: number
  contractLabel?: string
  contractAddress?: string
  websiteUrl?: string
  xUrl?: string
  /** Base total-supplied USD used to seed the supply chart. */
  baseSuppliedUsd?: number
  /** Base total-borrowed USD used to seed the borrow chart. */
  baseBorrowedUsd?: number
  /** Subtitle shown under the hero. */
  subtitle?: string
  about?: AboutCard
  risk?: RiskAssessment
  quickStats?: Record<string, Partial<QuickStat>>
}

const ASSET_FIXTURES: Record<string, AssetFixture> = {
  usdc: {
    chain: "Ethereum",
    heroPriceUsd: 1,
    heroPriceChangePct: 0.02,
    contractLabel: "0xA0b8…6eB48",
    contractAddress: "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    websiteUrl: "https://www.circle.com/usdc",
    xUrl: "https://x.com/circle",
    baseSuppliedUsd: 205_670_000,
    baseBorrowedUsd: 166_240_000,
    subtitle:
      "The deepest stablecoin on the protocol — borrowed to lever up LP collateral and for stable-to-stable carry.",
    quickStats: {
      available: { value: "$39.43M", delta: { value: 0.6, direction: "up", label: "+0.6%" } },
      supplyApy: { value: "6.32%" },
      borrowApy: { value: "7.44%" },
    },
    about: {
      description:
        "USDC is Circle's regulated, fully-backed USD stablecoin and the main unit of account for this market. It anchors the protocol's conservative borrow curves, acts as the default settlement asset for LP carry strategies, and serves as the reference point for risk pricing across stablecoin routes. In practice, that makes it the most common asset for users who want cash-like exposure with on-chain mobility.",
      stats: [],
      history: [
        { date: "2024-04-01", title: "Launch", description: "USDC listed day-1 with 80% borrow cap." },
        {
          date: "2025-03-09",
          title: "De-peg drill",
          description: "Simulated 2023-style de-peg; guardrails paused borrows for 18m.",
        },
        {
          date: "2026-01-22",
          title: "Cap raised",
          description: "Supply cap raised to $250M after utilization sustained >75% for 30 days.",
        },
      ],
    },
    risk: {
      premiumBps: 25,
      level: "low",
      score: 14,
      headline: "Low risk · +0.25% premium",
      summary:
        "USDC is the benchmark stable. Depeg tail is the dominant risk; monitored by deviation guards and Circle attestations.",
      breakdown: [
        {
          id: "depeg",
          label: "De-peg tail",
          bps: 12,
          level: "low",
          description: "Guardrails pause borrows on >50bps Chainlink deviation for 5m.",
        },
        {
          id: "issuer",
          label: "Issuer solvency",
          bps: 6,
          level: "low",
          description: "Weekly Circle attestations ingested into the oracle pipeline.",
        },
        {
          id: "bridge",
          label: "Bridge surface",
          bps: 4,
          level: "low",
          description: "Canonical bridge only; non-canonical deployments are blocked.",
        },
        {
          id: "sc",
          label: "Smart-contract surface",
          bps: 3,
          level: "low",
          description: "Standard ERC-20 implementation.",
        },
      ],
      metrics: [
        { id: "peg", label: "30d peg deviation (max)", value: "7 bps" },
        { id: "supplyCap", label: "Supply cap", value: "$250M" },
        { id: "oracle", label: "Oracle", value: "Chainlink USDC/USD" },
        { id: "issuer", label: "Issuer", value: "Circle (US)" },
      ],
      lastReviewed: "2026-03-18",
    },
  },
  eth: {
    chain: "Ethereum",
    heroPriceUsd: 1791.81,
    heroPriceChangePct: -12.9,
    contractLabel: "7vfC...voxs",
    contractAddress: "7vfC2Jf2voxs",
    websiteUrl: "https://ethereum.org",
    xUrl: "https://x.com/ethereum",
    baseSuppliedUsd: 168_400_000,
    baseBorrowedUsd: 92_600_000,
    subtitle: "Native ETH — the primary volatile borrow asset for directional carry on LP collateral.",
    about: {
      description:
        "Ethereum is a decentralized blockchain with smart contract functionality. Ether is the native cryptocurrency of the platform and is used to pay for transaction fees and computational services on the network. It is the second-largest cryptocurrency by market capitalization and powers the majority of decentralized finance activity.",
      stats: [
        {
          label: "Vault Contract Address",
          value: "0x1828...47E8",
          href: "https://etherscan.io/address/0x182847E8",
        },
        {
          label: "Token Contract Address",
          value: "0xdC03...384F",
          href: "https://etherscan.io/address/0xDC03384F",
        },
        {
          label: "Risk Manager Address",
          value: "0xd57a...7B15",
          href: "https://etherscan.io/address/0xd57a7B15",
        },
        {
          label: "Oracle Router Address",
          value: "0xa1b2...C3D4",
          href: "https://etherscan.io/address/0xa1b2C3D4",
        },
        { label: "Deployed On", value: "October 7, 2024" },
      ],
      history: [
        { date: "2015-07-30", title: "Mainnet launch", description: "Ethereum genesis block mined." },
        { date: "2022-09-15", title: "The Merge", description: "Proof-of-stake consensus activated." },
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
  weth: {
    chain: "Ethereum",
    heroPriceUsd: 2021.44,
    heroPriceChangePct: -5.12,
    contractLabel: "0xC02a…6Cc2",
    contractAddress: "0xC02aaA39b223FE8D0A0E5C4F27eAD9083C756Cc2",
    websiteUrl: "https://weth.io",
    xUrl: "https://x.com/ethereum",
    baseSuppliedUsd: 204_100_000,
    baseBorrowedUsd: 118_300_000,
    subtitle: "Wrapped ETH is the canonical ERC-20 used by Uniswap/Balancer/Aerodrome pools.",
  },
  wbtc: {
    chain: "Ethereum",
    heroPriceUsd: 68422.18,
    heroPriceChangePct: -2.41,
    contractLabel: "0x2260…C599",
    contractAddress: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
    websiteUrl: "https://wbtc.network",
    xUrl: "https://x.com/WrappedBTC",
    baseSuppliedUsd: 96_200_000,
    baseBorrowedUsd: 42_300_000,
    subtitle: "Wrapped BTC exposure — borrowed to short BTC against blue-chip LPs.",
  },
}

// -------------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------------

/**
 * Hero "Price" basis for a borrowable. Prefers the canonical snapshot (`canonicalPriceUsd`) so the
 * mock tile shows the SAME number as the Convex tile (which reads the same baseline via
 * injectBaselinePrice) and the price chart's canonical-anchored terminal. Falls back to the fixture
 * pin, then a per-category default, only when the symbol is unpriced.
 */
function resolveHeroPriceUsd(asset: SpokeBorrowableRecord, fixture: AssetFixture | undefined): number {
  return (
    canonicalPriceUsd(asset.symbol) ??
    fixture?.heroPriceUsd ??
    (asset.category === "stable" ? 1 : asset.category === "btc" ? 68422.18 : 2019.96)
  )
}

function deltaFromPct(pct: number): DeltaStat {
  if (pct === 0) return { value: 0, direction: "flat", label: "0.0%" }
  return pct > 0
    ? { value: pct, direction: "up", label: `+${pct.toFixed(1)}%` }
    : { value: pct, direction: "down", label: `${pct.toFixed(1)}%` }
}

function buildHero(asset: SpokeBorrowableRecord, fixture: AssetFixture | undefined): AssetDetailHero {
  const contractAddress = fixture?.contractAddress ?? contractAddressFor(asset.id, "token")
  const contractLabel =
    fixture?.contractLabel ??
    (/^0x[a-fA-F0-9]{40}$/.test(contractAddress) ? shortAddress(contractAddress) : contractAddress)
  return {
    visual: asset.visual,
    name: asset.name,
    symbol: asset.symbol,
    subtitle: fixture?.subtitle
      ? `${fixture.subtitle} Available through ${asset.spokeLabel}.`
      : `${asset.name} — ${asset.subtitle}.`,
    chain: fixture?.chain ?? "Ethereum",
    category: asset.category === "stable" ? "stable" : "crypto",
    contractLabel,
    contractAddress,
    websiteUrl: fixture?.websiteUrl,
    xUrl: fixture?.xUrl,
  }
}

function reserveFactorPct(asset: SpokeBorrowableRecord) {
  return asset.category === "stable" ? 10 : 15
}

function buildQuickStats(
  asset: SpokeBorrowableRecord,
  supplied: number,
  borrowed: number,
  fixture: AssetFixture | undefined,
): QuickStat[] {
  const heroPriceUsd = resolveHeroPriceUsd(asset, fixture)
  const availableUsd = Math.max(0, supplied - borrowed)
  const defaults: QuickStat[] = [
    { id: "price", label: "Price", value: formatUsdPrice(heroPriceUsd), delta: deltaFromPct(0.1) },
    {
      id: "available",
      label: "Available Liquidity",
      value: formatCompactUsd(availableUsd),
      delta: deltaFromPct(0.6),
    },
    {
      id: "supplyApy",
      label: "Supply APY",
      value: `${(asset.borrowApr * 0.85).toFixed(2)}%`,
      delta: deltaFromPct(0.1),
    },
    { id: "rewardsApy", label: "Rewards APY", value: "No rewards" },
    { id: "borrowApy", label: "Borrow APR", value: `${asset.borrowApr.toFixed(2)}%`, delta: deltaFromPct(0.08) },
    { id: "reserveFactor", label: "Reserve Factor", value: `${reserveFactorPct(asset)}%` },
  ]
  if (!fixture?.quickStats) return defaults
  return defaults.map((stat) => ({ ...stat, ...(fixture.quickStats?.[stat.id] ?? {}) }))
}

function formatUsdPrice(value: number): string {
  return value >= 100
    ? `$${value.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
    : `$${value.toFixed(2)}`
}

function buildHeroSeries(
  asset: SpokeBorrowableRecord,
  supplied: number,
  borrowed: number,
  fixture: AssetFixture | undefined,
): Record<AssetChartMetricId, Record<TimeRangeId, Series>> {
  const utilizationBase = Math.max(1, Math.min(95, (borrowed / supplied) * 100))
  const apyBase = asset.borrowApr
  const priceBase = resolveHeroPriceUsd(asset, fixture)
  const curatedPrice = buildCuratedPriceFamily(asset.baseAssetId, "Price")
  return {
    // Anchor the price chart's terminal to the canonical basis so the chart ends exactly where the
    // "Price" tile sits (see anchorPriceFamilyToCanonical); the synthetic base is canonical too.
    price: anchorPriceFamilyToCanonical(
      curatedPrice ??
        buildSeriesFamily(`${asset.id}:price`, "Price", {
          base: priceBase,
          driftMultiplier: 0.98,
          noise: 0.02,
          wave: 0.035,
          nonNegative: true,
          roundTo: 2,
        }),
      asset.symbol,
    ),
    supply: buildSeriesFamily(`${asset.id}:supply`, "Total Supplied", {
      base: supplied,
      driftMultiplier: 1.08,
      noise: 0.03,
      wave: 0.05,
      nonNegative: true,
      roundTo: 0,
    }),
    borrow: buildSeriesFamily(`${asset.id}:borrow`, "Total Borrowed", {
      base: borrowed,
      driftMultiplier: 1.06,
      noise: 0.04,
      wave: 0.06,
      nonNegative: true,
      roundTo: 0,
    }),
    utilization: buildSeriesFamily(`${asset.id}:util`, "Utilization", {
      base: utilizationBase,
      driftMultiplier: 1.02,
      noise: 0.05,
      wave: 0.08,
      nonNegative: true,
      roundTo: 2,
    }),
    apy: buildSeriesFamily(`${asset.id}:apy`, "Borrow APY", {
      base: apyBase,
      driftMultiplier: 1.04,
      noise: 0.08,
      wave: 0.1,
      nonNegative: true,
      roundTo: 2,
    }),
  }
}

function buildSupplyBorrow(asset: SpokeBorrowableRecord, supplied: number, borrowed: number) {
  return {
    supplied: buildSeries(`${asset.id}:sb:supply`, "1Y", "Supplied", {
      base: supplied,
      driftMultiplier: 1.12,
      noise: 0.04,
      nonNegative: true,
      roundTo: 0,
    }),
    borrowed: buildSeries(`${asset.id}:sb:borrow`, "1Y", "Borrowed", {
      base: borrowed,
      driftMultiplier: 1.09,
      noise: 0.05,
      nonNegative: true,
      roundTo: 0,
    }),
    utilization: buildSeries(`${asset.id}:sb:util`, "1Y", "Utilization", {
      base: Math.max(1, Math.min(95, (borrowed / supplied) * 100)),
      driftMultiplier: 1.02,
      noise: 0.05,
      nonNegative: true,
      roundTo: 2,
    }),
  }
}

function buildInterestGenerated(asset: SpokeBorrowableRecord, borrowed: number): Record<PerfPeriod, PerfTabDataset> {
  const periods: Record<PerfPeriod, { scale: number; label: string }> = {
    weekly: { scale: 7, label: "7d" },
    monthly: { scale: 30, label: "30d" },
    quarterly: { scale: 90, label: "90d" },
  }
  const dailyInterest = (borrowed * (asset.borrowApr / 100)) / 365
  const out = {} as Record<PerfPeriod, PerfTabDataset>
  for (const period of ALL_PERF_PERIODS) {
    const { scale, label } = periods[period]
    const base = dailyInterest * scale
    out[period] = {
      headline: formatCompactUsd(base),
      subLabel: `vs previous ${label} ${deltaForPeriod(asset.id, period)}`,
      series: buildSeries(`${asset.id}:int:${period}`, "1M", "Interest", {
        base: dailyInterest,
        driftMultiplier: 1.06,
        noise: 0.18,
        nonNegative: true,
        roundTo: 0,
      }),
      breakdown: [
        { label: "To suppliers", value: formatCompactUsd(base * 0.9), delta: deltaFromPct(3.2) },
        { label: "Reserve", value: formatCompactUsd(base * 0.1), delta: deltaFromPct(3.2) },
      ],
    }
  }
  return out
}

function deltaForPeriod(id: string, period: PerfPeriod): string {
  const r = prngFromString(`${id}:${period}`)()
  const pct = Math.round((r * 16 - 4) * 10) / 10
  return `${pct >= 0 ? "+" : ""}${pct.toFixed(1)}%`
}

function buildAssetCashflow(asset: SpokeBorrowableRecord, supplied: number, borrowed: number): CashflowCard {
  const annualInterest = (borrowed * asset.borrowApr) / 100
  const feesSeries = buildSeries(`${asset.id}:cf:interest`, "1Y", "Interest", {
    base: annualInterest / 12,
    driftMultiplier: 1.04,
    noise: 0.08,
    nonNegative: true,
    roundTo: 0,
  })
  const rewardsSeries = buildSeries(`${asset.id}:cf:rewards`, "1Y", "Rewards", {
    base: (supplied * 0.002) / 12,
    driftMultiplier: 1.05,
    noise: 0.18,
    nonNegative: true,
    roundTo: 0,
  })
  return {
    bars: [feesSeries, rewardsSeries],
    periodLabel: "Last 12 months",
    rows: [
      {
        label: "Interest paid by borrowers",
        reported: formatCompactUsd(annualInterest),
        yoy: deltaFromPct(14.2),
        highlighted: true,
      },
      { label: "To suppliers", reported: formatCompactUsd(annualInterest * 0.9), yoy: deltaFromPct(13.8) },
      { label: "Reserve", reported: formatCompactUsd(annualInterest * 0.1), yoy: deltaFromPct(16.4) },
      { label: "Rewards distributed", reported: formatCompactUsd(supplied * 0.002), yoy: deltaFromPct(4.1) },
      {
        label: "Net to suppliers",
        reported: formatCompactUsd(annualInterest * 0.9 + supplied * 0.002),
        yoy: deltaFromPct(12.8),
        highlighted: true,
      },
    ],
  }
}

function buildCashflowTrend(asset: SpokeBorrowableRecord, _supplied: number, borrowed: number): CashflowTrend {
  const annualInterest = borrowed * (asset.borrowApr / 100)
  const monthlyGross = annualInterest / 12
  const rand = prngFromString(`${asset.id}:cf:trend`)
  const now = SANDBOX_NOW

  const points: Series["points"] = []
  for (let i = 11; i >= 0; i--) {
    const d = new Date(now)
    d.setUTCMonth(d.getUTCMonth() - i, 1)
    const t = d.toISOString().slice(0, 10)
    const wave = 1 + Math.sin(((11 - i) / 11) * Math.PI * 2) * 0.18
    const noise = 1 + (rand() - 0.5) * 0.24
    const gross = Math.max(0, Math.round(monthlyGross * wave * noise))
    points.push({ t, v: gross })
  }

  const total = points.reduce((a, p) => a + p.v, 0)
  return {
    totalLabel: formatCompactUsd(total),
    periodLabel: "Yearly",
    series: {
      id: `${asset.id}:cf:revenue`,
      label: "Revenue",
      points,
      aggregate: total / 12,
    },
  }
}

function buildAssetRisk(asset: SpokeBorrowableRecord, fixture: AssetFixture | undefined): RiskAssessment {
  if (fixture?.risk) return fixture.risk
  // Single source of truth shared with the Convex seed (build-seed.ts) so the
  // seeded risk row is identical to this fallback.
  return buildAssetRiskAssessment(asset)
}

function contractAddressFor(assetId: string, salt: string) {
  const seed = `${assetId}:${salt}`
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

function buildAssetGovernanceParameters(
  asset: SpokeBorrowableRecord,
  supplied: number,
  borrowed: number,
): NonNullable<AboutCard["governanceParameters"]> {
  const isStable = asset.category === "stable"
  const ltvPct = isStable ? 78 : 72
  const liquidationThresholdPct = isStable ? 83 : 78
  const liquidationBonusPct = isStable ? 5 : 7
  const supplyCapUsd = Math.max(25_000_000, Math.ceil((supplied * 1.75) / 1_000_000) * 1_000_000)
  const borrowCapUsd = Math.max(10_000_000, Math.ceil((borrowed * 2.25) / 1_000_000) * 1_000_000)
  const proposalHref = `https://etherscan.io/address/${contractAddressFor(asset.id, "governance")}`
  const reserve = reserveFactorPct(asset)

  return {
    parameters: buildRiskParameterSet({
      collateralFactorPct: ltvPct,
      liquidationThresholdPct,
      depositCapacityLabel: formatCompactUsd(supplyCapUsd),
      borrowCapacityLabel: formatCompactUsd(borrowCapUsd),
      liquidationPenaltyPct: liquidationBonusPct,
      collateralFactorDescription: "Maximum borrow power when this supplied asset is used as collateral.",
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
        href: proposalHref,
      },
      {
        id: "reserve-factor-review",
        parameter: "Reserve factor",
        previous: `${Math.max(0, reserve - 1)}%`,
        current: `${reserve}%`,
        date: "2025-06-02",
        source: "Revenue parameter update",
        executor: "Risk steward multisig",
        href: proposalHref,
      },
      {
        id: "collateral-onboarding",
        parameter: "Collateral configuration",
        previous: "Disabled",
        current: `${ltvPct}% CF / ${liquidationThresholdPct}% LT`,
        date: "2025-01-20",
        source: "Market onboarding",
        executor: "Governance executor",
        href: proposalHref,
      },
    ],
  }
}

function buildAssetAbout(
  asset: SpokeBorrowableRecord,
  fixture: AssetFixture | undefined,
  supplied: number,
  borrowed: number,
): AboutCard {
  const about = fixture?.about ?? {
    description:
      `${asset.name} (${asset.symbol}) is a core borrowable market in ${asset.spokeLabel} and a building block for directional hedges and LP carry loops within that spoke. ` +
      `${asset.subtitle} The borrow APY is influenced by utilization, reserve settings, and demand inside ${asset.spokeLabel}, so the page focuses on the live rate, the supply/borrow mix, and the latest risk posture.`,
    stats: [],
    history: [
      { date: "2025-02-10", title: "Listed", description: `${asset.symbol} listed with conservative borrow cap.` },
      { date: "2025-11-18", title: "Parameters refreshed", description: "Quarterly risk review — no changes." },
    ],
  }

  // Contract-address stats now injected at overlay time by getAssetDetailFromConvex via
  // api.contractAddresses.listAssetAddresses. The hero contract address (top of page)
  // still uses the local FNV synthetic — see buildHero — because the Convex swap for
  // that field is a separate concern (fixture pins take precedence there).
  return {
    ...about,
    stats: [],
    governanceParameters: buildAssetGovernanceParameters(asset, supplied, borrowed),
  }
}

function buildTransactions(asset: SpokeBorrowableRecord): TxHistoryRow[] {
  const rand = prngFromString(`${asset.id}:tx`)
  const kinds: TxHistoryRow["kind"][] = ["supply", "borrow", "repay", "withdraw", "rewards", "liquidation"]
  const priceUsd = canonicalPriceUsd(asset.baseAssetId) ?? 1
  const out: TxHistoryRow[] = []
  const now = Date.now()
  for (let i = 0; i < 12; i++) {
    const kind = kinds[Math.floor(rand() * kinds.length)]
    const amount = Math.round((10_000 + rand() * 240_000) / 100) * 100
    const ageMs = i * 28_000 + Math.floor(rand() * 6_000)
    const at = new Date(now - ageMs).toISOString()
    const walletAddress = `0x${Math.floor(rand() * 0xffffffff)
      .toString(16)
      .padStart(8, "0")}${Math.floor(rand() * 0xffffffff)
      .toString(16)
      .padStart(8, "0")}${Math.floor(rand() * 0xffffffff)
      .toString(16)
      .padStart(8, "0")}${Math.floor(rand() * 0xffffffff)
      .toString(16)
      .padStart(8, "0")}${Math.floor(rand() * 0xffffffff)
      .toString(16)
      .padStart(8, "0")}`
    const walletLabel = `${walletAddress.slice(0, 6)}...${walletAddress.slice(-4)}`
    out.push({
      id: `${asset.id}-tx-${i}`,
      at,
      timeLabel: formatRelativeAge(ageMs),
      kind,
      amountLabel: `${kind === "withdraw" ? "-" : "+"}${formatCompactUsd(amount)}`,
      tokenAmountLabel: formatDetailTokenAmount(amount / priceUsd),
      tokenSymbol: asset.baseAssetId.toUpperCase(),
      counterpartyLabel: kind === "liquidation" ? "Liquidator" : undefined,
      walletLabel,
      walletHref: `https://etherscan.io/address/${walletAddress}`,
      txHashShort: `0x${Math.floor(rand() * 0xffffff)
        .toString(16)
        .padStart(6, "0")}…${Math.floor(rand() * 0xffff)
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

// -------------------------------------------------------------------------
// Public
// -------------------------------------------------------------------------

export function resolveAsset(id: string): SpokeBorrowableRecord | null {
  if (!id) return null
  return resolveSpokeBorrowable(id)
}

export function buildAssetDetail(asset: SpokeBorrowableRecord): AssetDetail {
  const fixture = ASSET_FIXTURES[asset.baseAssetId]
  const supplied = fixture?.baseSuppliedUsd ?? Math.max(asset.totalBorrowedUsd + asset.availableUsd, 1)
  const borrowed = fixture?.baseBorrowedUsd ?? asset.totalBorrowedUsd
  const allocation: AllocationRow[] = computeAssetAllocation(asset, BORROW_POOL_CATALOG)
  const heroPriceUsd = resolveHeroPriceUsd(asset, fixture)
  const heroPriceChangePct = fixture?.heroPriceChangePct ?? -2.14
  return {
    id: asset.id,
    hero: buildHero(asset, fixture),
    heroMetric: {
      metricId: "price",
      valueLabel:
        heroPriceUsd >= 100
          ? `$${heroPriceUsd.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
          : `$${heroPriceUsd.toFixed(2)}`,
      delta: deltaFromPct(heroPriceChangePct),
      series: buildHeroSeries(asset, supplied, borrowed, fixture),
    },
    quickStats: buildQuickStats(asset, supplied, borrowed, fixture),
    protocolParameters: buildAssetProtocolParameters(asset),
    supplyBorrow: buildSupplyBorrow(asset, supplied, borrowed),
    interestGenerated: buildInterestGenerated(asset, borrowed),
    historicalUtilization: buildSeries(`${asset.id}:hist:util`, "1Y", "Utilization", {
      base: (borrowed / supplied) * 100,
      driftMultiplier: 1.02,
      noise: 0.08,
      nonNegative: true,
      roundTo: 2,
    }),
    cashflowTrend: buildCashflowTrend(asset, supplied, borrowed),
    allocation,
    cashflow: buildAssetCashflow(asset, supplied, borrowed),
    risk: buildAssetRisk(asset, fixture),
    about: buildAssetAbout(asset, fixture, supplied, borrowed),
    faqs: buildAssetFaqs(asset.symbol, asset.name),
    transactions: buildTransactions(asset),
    row: asset,
  }
}

/** About card for seeding the Convex content layer (mirrors what the detail page renders). */
export function getAssetAboutCard(asset: SpokeBorrowableRecord): AboutCard {
  const fixture = ASSET_FIXTURES[asset.baseAssetId]
  const supplied = fixture?.baseSuppliedUsd ?? Math.max(asset.totalBorrowedUsd + asset.availableUsd, 1)
  const borrowed = fixture?.baseBorrowedUsd ?? asset.totalBorrowedUsd
  return buildAssetAbout(asset, fixture, supplied, borrowed)
}

for (const id of ALL_ASSET_CHART_METRICS) void id
