/**
 * Deterministic `LendMarketDetail` factory.
 *
 * Mirrors `borrow-detail/asset.mock.ts` and `multiply-detail` but for single-asset
 * supply markets. Every section is seeded by the market id so the output is stable
 * (same id in → same charts out). Risk and FAQs delegate to the shared builders
 * (`buildLendRiskAssessment`, `buildLendFaqs`) that the Convex seed also uses, so
 * the procedural fallback is byte-for-byte identical to seeded data.
 *
 * The Convex layer (`./convex-detail.ts`) passes `overrides` from the live snapshot
 * so the headline numbers match the list / hero; absent overrides, the catalog
 * values drive everything.
 */

import { formatCompactUsd } from "@/app/lib/borrow-sim"
import { formatPct } from "@/app/lib/borrow-detail"
import { buildSeries, prngFromString } from "@/app/lib/borrow-detail/prng"
import { SANDBOX_NOW } from "@/app/lib/deterministic"
import { buildLendRiskAssessment } from "@/app/lib/borrow-detail/risk-model"
import { buildLendFaqs } from "@/app/lib/borrow-detail/content-model"
import { getLocalAssetIcon } from "@/app/lib/local-asset-icons"
import { getLendMarketById, resolveLendMarketId } from "@/app/lib/lend-system/catalog"
import type { LendMarket } from "@/app/lib/lend-engine/types"
import type {
  AboutCard,
  CashflowCard,
  DeltaStat,
  QuickStat,
  RiskAssessment,
  TxHistoryRow,
} from "@/app/lib/borrow-detail"
import { buildInterestRateModelParameterRows } from "@/app/lib/borrow-detail/protocol-parameters"
import { buildRiskParameterSet } from "@/app/lib/borrow-detail/risk-parameters"
import { formatDetailTokenAmount } from "@/app/lib/detail-page/transaction-display"
import type { LendMarketDetail, LendMarketHero, LendTokenVisual } from "./types"

/** Reference values from a Convex snapshot, threaded into the headline numbers. */
export type LendDetailOverrides = {
  suppliedUsd?: number
  borrowedUsd?: number
  availableUsd?: number
  utilizationPct?: number
  supplyApyPct?: number
  borrowAprPct?: number
}

const HERO_ANCHOR = SANDBOX_NOW

function deltaFromPct(pct: number): DeltaStat {
  if (pct === 0) return { value: 0, direction: "flat", label: "0.0%" }
  return pct > 0
    ? { value: pct, direction: "up", label: `+${pct.toFixed(1)}%` }
    : { value: pct, direction: "down", label: `${pct.toFixed(1)}%` }
}

function getVisual(symbol: string): LendTokenVisual {
  return {
    symbol,
    shortLabel: symbol.slice(0, 2).toUpperCase(),
    bgClass: "bg-surface-inset",
    textClass: "text-foreground",
    iconUrl: getLocalAssetIcon(symbol),
  }
}

type Reference = {
  price: number
  suppliedUsd: number
  borrowedUsd: number
  availableUsd: number
  utilizationPct: number
  supplyApyPct: number
  rewardsApyPct: number
  borrowAprPct: number
  reserveFactorPct: number
}

/** Resolve the headline reference values from the catalog, overlaid by Convex overrides. */
function resolveReference(market: LendMarket, overrides?: LendDetailOverrides): Reference {
  const price = market.assetPriceUsd
  const suppliedUsd = overrides?.suppliedUsd ?? Math.max(1, market.totalSupplied * price)
  const utilizationPct = clampPct(overrides?.utilizationPct ?? market.utilization * 100)
  const borrowedUsd = overrides?.borrowedUsd ?? (suppliedUsd * utilizationPct) / 100
  const availableUsd = overrides?.availableUsd ?? Math.max(0, suppliedUsd - borrowedUsd)
  const supplyApyPct = overrides?.supplyApyPct ?? market.supplyApy * 100
  const reserveFactorPct = market.reserveFactor * 100
  // Implied borrow APR from supply = borrow · utilization · (1 − reserveFactor).
  const borrowAprPct =
    overrides?.borrowAprPct ??
    supplyApyPct / Math.max(0.05, utilizationPct / 100) / Math.max(0.5, 1 - market.reserveFactor)
  return {
    price,
    suppliedUsd,
    borrowedUsd,
    availableUsd,
    utilizationPct,
    supplyApyPct,
    rewardsApyPct: market.rewardsApy * 100,
    borrowAprPct,
    reserveFactorPct,
  }
}

function clampPct(v: number): number {
  return Math.min(99, Math.max(0, v))
}

function buildHero(market: LendMarket): LendMarketHero {
  const isStable = market.riskTier === "low"
  return {
    visual: getVisual(market.asset.symbol),
    name: market.asset.name,
    symbol: market.asset.symbol,
    subtitle: `${market.asset.name} (${market.asset.symbol}) is a single-asset supply market on Avana — deposit to earn the supply APY${
      market.rewardsApy > 0 ? " plus active rewards" : ""
    }, with ${isStable ? "conservative stablecoin" : "tier-based"} risk parameters.`,
    chain: "Ethereum",
    category: isStable ? "stable" : "crypto",
    venue: "Avana Lend",
  }
}

function buildQuickStats(market: LendMarket, ref: Reference): QuickStat[] {
  return [
    { id: "price", label: "Price", value: formatUsdPrice(ref.price), delta: deltaFromPct(0.1) },
    {
      id: "available",
      label: "Available Liquidity",
      value: formatCompactUsd(ref.availableUsd),
      delta: deltaFromPct(0.6),
    },
    { id: "supplyApy", label: "Supply APY", value: formatPct(ref.supplyApyPct, 2), delta: deltaFromPct(0.1) },
    {
      id: "rewardsApy",
      label: "Rewards APY",
      value: ref.rewardsApyPct > 0 ? formatPct(ref.rewardsApyPct, 2) : "No rewards",
    },
    { id: "borrowApy", label: "Borrow APY", value: formatPct(ref.borrowAprPct, 2), delta: deltaFromPct(0.08) },
    { id: "reserveFactor", label: "Reserve Factor", value: formatPct(ref.reserveFactorPct, 0) },
  ]
}

function formatUsdPrice(value: number): string {
  return value >= 100
    ? `$${value.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
    : `$${value.toFixed(2)}`
}

function buildSupplyBorrow(market: LendMarket, ref: Reference) {
  return {
    supplied: buildSeries(`lend:${market.marketId}:sb:supply`, "1Y", "Supplied", {
      base: ref.suppliedUsd,
      driftMultiplier: 1.12,
      noise: 0.04,
      nonNegative: true,
      roundTo: 0,
    }),
    borrowed: buildSeries(`lend:${market.marketId}:sb:borrow`, "1Y", "Borrowed", {
      base: ref.borrowedUsd,
      driftMultiplier: 1.09,
      noise: 0.05,
      nonNegative: true,
      roundTo: 0,
    }),
    utilization: buildSeries(`lend:${market.marketId}:sb:util`, "1Y", "Utilization", {
      base: Math.max(1, ref.utilizationPct),
      driftMultiplier: 1.02,
      noise: 0.05,
      nonNegative: true,
      roundTo: 2,
    }),
  }
}

function buildCashflow(market: LendMarket, ref: Reference): CashflowCard {
  const annualInterest = (ref.borrowedUsd * ref.borrowAprPct) / 100
  const toSuppliers = annualInterest * (1 - market.reserveFactor)
  const reserve = annualInterest * market.reserveFactor
  const rewards = (ref.suppliedUsd * ref.rewardsApyPct) / 100
  const feesSeries = buildSeries(`lend:${market.marketId}:cf:interest`, "1Y", "Interest", {
    base: annualInterest / 12,
    driftMultiplier: 1.04,
    noise: 0.08,
    nonNegative: true,
    roundTo: 0,
  })
  const rewardsSeries = buildSeries(`lend:${market.marketId}:cf:rewards`, "1Y", "Rewards", {
    base: rewards / 12,
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
        yoy: deltaFromPct(13.4),
        highlighted: true,
      },
      { label: "To suppliers", reported: formatCompactUsd(toSuppliers), yoy: deltaFromPct(12.9) },
      { label: "Reserve", reported: formatCompactUsd(reserve), yoy: deltaFromPct(15.2) },
      { label: "Rewards distributed", reported: formatCompactUsd(rewards), yoy: deltaFromPct(4.1) },
      {
        label: "Net to suppliers",
        reported: formatCompactUsd(toSuppliers + rewards),
        yoy: deltaFromPct(11.8),
        highlighted: true,
      },
    ],
  }
}

function buildTransactions(market: LendMarket): TxHistoryRow[] {
  const rand = prngFromString(`lend:${market.marketId}:tx`)
  const kinds: TxHistoryRow["kind"][] = ["supply", "withdraw", "rewards", "supply", "withdraw", "supply"]
  const out: TxHistoryRow[] = []
  const now = HERO_ANCHOR
  for (let i = 0; i < 12; i++) {
    const kind = kinds[Math.floor(rand() * kinds.length)]!
    const amount = Math.round((5_000 + rand() * 180_000) / 100) * 100
    const ageMs = i * 31_000 + Math.floor(rand() * 6_000)
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
    const walletLabel = `${walletAddress.slice(0, 6)}…${walletAddress.slice(-4)}`
    out.push({
      id: `lend-${market.marketId}-tx-${i}`,
      at,
      timeLabel: formatRelativeAge(ageMs),
      kind,
      amountLabel: `${kind === "withdraw" ? "-" : "+"}${formatCompactUsd(amount)}`,
      tokenAmountLabel: formatDetailTokenAmount(amount / market.assetPriceUsd),
      tokenSymbol: market.asset.symbol,
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
  if (totalMinutes < 60) return `${totalMinutes}m`
  const totalHours = Math.floor(totalMinutes / 60)
  if (totalHours < 24) return `${totalHours}h`
  return `${Math.floor(totalHours / 24)}d`
}

function contractAddressFor(market: LendMarket, salt: string) {
  const seed = `${market.marketId}:${salt}`
  let hash = 0x811c9dc5
  for (let index = 0; index < seed.length; index += 1) {
    hash ^= seed.charCodeAt(index)
    hash = Math.imul(hash, 0x01000193)
  }
  const chunk = (hash >>> 0).toString(16).padStart(8, "0").toUpperCase()
  return `0x${chunk}${chunk}${chunk}${chunk}${chunk}`.slice(0, 42)
}

function buildGovernanceParameters(market: LendMarket, ref: Reference): AboutCard["governanceParameters"] {
  const isStable = market.riskTier === "low"
  const ltvPct = isStable ? 78 : 72
  const liquidationThresholdPct = isStable ? 83 : 78
  const liquidationBonusPct = isStable ? 5 : 7
  const supplyCapUsd = Math.max(25_000_000, Math.ceil((ref.suppliedUsd * 1.75) / 1_000_000) * 1_000_000)
  const borrowCapUsd = Math.max(10_000_000, Math.ceil((ref.borrowedUsd * 2.25) / 1_000_000) * 1_000_000)
  const proposalHref = `https://etherscan.io/address/${contractAddressFor(market, "governance")}`

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
        previous: `${Math.max(0, Math.round(market.reserveFactor * 100) - 1)}%`,
        current: `${Math.round(market.reserveFactor * 100)}%`,
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

function buildAbout(market: LendMarket, ref: Reference): AboutCard {
  const isStable = market.riskTier === "low"
  return {
    description:
      `${market.asset.name} (${market.asset.symbol}) is a single-asset supply market on Avana. ` +
      `Deposit to earn the supply APY${market.rewardsApy > 0 ? " plus active rewards" : ""}, and withdraw available liquidity anytime. ` +
      `Yield tracks borrower demand, utilization, reserve settings, and market liquidity, so supplier returns can move as deposits and borrows rebalance. ` +
      `The page focuses on the live supply rate, the supply/borrow mix, available liquidity, and the latest risk posture for this ${
        isStable ? "stablecoin" : "tier-" + market.riskTier
      } market. Suppliers should watch utilization, reserve factor, oracle quality, and withdrawal depth because those inputs affect both earned yield and how quickly capital can exit during stressed conditions.`,
    stats: [
      // Contract addresses injected from lendContractAddresses at Convex overlay time.
    ],
    history: [
      {
        date: isStable ? "March 18, 2024" : "October 7, 2024",
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
    governanceParameters: buildGovernanceParameters(market, ref),
  }
}

// -------------------------------------------------------------------------
// Public
// -------------------------------------------------------------------------

/** Resolve a lend market by its route id (market id or asset symbol). */
export function resolveLendMarket(id: string): LendMarket | null {
  if (!id) return null
  const decoded = decodeURIComponent(id).trim()
  return getLendMarketById(decoded) ?? getLendMarketById(resolveLendMarketId(decoded))
}

/**
 * Key Statistics and the Risk card both surface "Supply APY". Key Statistics reflects the
 * live snapshot rate while the seeded/catalog risk metric is frozen, so on the live detail
 * page the two can disagree. Overlay the risk metric with the exact value Key Statistics
 * renders so the page shows a single Supply APY. No-op when they already match or when the
 * metric / stat is absent.
 */
export function alignRiskSupplyApyMetric(risk: RiskAssessment, quickStats: QuickStat[]): RiskAssessment {
  const headline = quickStats.find((stat) => stat.id === "supplyApy")?.value
  if (!headline || !risk.metrics.some((metric) => metric.id === "supplyApy" && metric.value !== headline)) {
    return risk
  }
  return {
    ...risk,
    metrics: risk.metrics.map((metric) => (metric.id === "supplyApy" ? { ...metric, value: headline } : metric)),
  }
}

/** Build the full deterministic detail for a lend market, optionally overlaying Convex reference values. */
export function buildLendMarketDetail(market: LendMarket, overrides?: LendDetailOverrides): LendMarketDetail {
  const ref = resolveReference(market, overrides)
  const quickStats = buildQuickStats(market, ref)
  return {
    id: market.marketId,
    hero: buildHero(market),
    quickStats,
    utilizationPct: ref.utilizationPct,
    borrowAprPct: ref.borrowAprPct,
    protocolParameters: buildInterestRateModelParameterRows(market.marketId, ref.borrowAprPct),
    supplyBorrow: buildSupplyBorrow(market, ref),
    cashflow: buildCashflow(market, ref),
    // Single-source Supply APY: keep the risk metric equal to the headline quick stat.
    risk: alignRiskSupplyApyMetric(buildLendRiskAssessment(market), quickStats),
    about: buildAbout(market, ref),
    faqs: buildLendFaqs(market.asset.symbol, market.asset.name),
    transactions: buildTransactions(market),
    row: market,
  }
}

/** About card for seeding the Convex content layer (mirrors what the detail page renders). */
export function getLendAboutCard(market: LendMarket): AboutCard {
  return buildAbout(market, resolveReference(market))
}
