/**
 * Shared, pure risk-assessment builders — the single source of truth for the
 * `RiskAssessment` shape on both detail pages.
 *
 * Both the mock fallback (`asset.mock.ts` / `pool.mock.ts`) AND the Convex seed
 * (`app/lib/convex-seed/build-seed.ts`) call these so the seeded product risk assessments
 * rows are byte-for-byte identical to the procedural fallback. That makes the
 * de-mock swap invisible to QA: the page renders the same numbers whether risk
 * comes from Convex or the catalog.
 *
 * Keep this module dependency-light (catalog + pure formatters only) so it can be
 * imported from the Node seed runner as well as client components.
 */

import { type BorrowPoolRow, aprRangeLabel, formatCompactUsd, getDexById, getSpokeById } from "@/app/lib/borrow-sim"
import type { SpokeBorrowableRecord } from "@/app/lib/borrow-system/registry"
import type { LendMarket } from "@/app/lib/lend-engine/types"
import type { MultiplyMarketRecord } from "@/app/lib/multiply-engine/types"
import { formatBpsAsPct, formatPct, riskLevelFromBps, riskLevelLabel, riskScoreFromBps } from "./allocation"
import { prngFromString } from "./prng"
import type { RiskAssessment } from "./types"

/**
 * Deterministic per-asset risk premium (bps). Base by category, then shifted by
 * utilization + borrow rate signals and a seeded spread so each gauge is distinct.
 * Kept here so the seed and the mock derive the identical premium.
 */
export function assetRiskPremiumBps(asset: SpokeBorrowableRecord): number {
  const isStable = asset.category === "stable"
  const base = isStable ? 28 : 110
  const utilAdj = (asset.utilization - 50) * (isStable ? 0.2 : 0.45)
  const aprAdj = (asset.borrowApr - (isStable ? 4 : 6)) * (isStable ? 1.4 : 2.2)
  const seed = prngFromString(`asset-risk:${asset.id}`)()
  const spread = (seed - 0.5) * (isStable ? 24 : 70)
  return Math.max(8, Math.round(base + utilAdj + aprAdj + spread))
}

/** Full risk rating for a borrowable asset. */
export function buildAssetRiskAssessment(asset: SpokeBorrowableRecord): RiskAssessment {
  const isStable = asset.category === "stable"
  const bps = assetRiskPremiumBps(asset)
  const level = riskLevelFromBps(bps)
  return {
    premiumBps: bps,
    level,
    score: riskScoreFromBps(bps),
    headline: `${riskLevelLabel(level)} risk · ${formatBpsAsPct(bps)} premium`,
    summary: isStable
      ? `${asset.symbol} is a stablecoin. Primary risk is a de-peg or issuer-solvency event; monitored by oracle deviation guards.`
      : `${asset.symbol} is a volatile asset used for directional carry. Primary risk is realized volatility and oracle latency under stress.`,
    breakdown: isStable
      ? [
          {
            id: "depeg",
            label: "De-peg tail",
            bps: Math.round(bps * 0.5),
            level: "low",
            description: "Guardrails pause new borrows on >50bps deviation for 5m.",
          },
          {
            id: "issuer",
            label: "Issuer solvency",
            bps: Math.round(bps * 0.3),
            level: "low",
            description: "Attestations / reserve reports monitored weekly.",
          },
          {
            id: "bridge",
            label: "Bridge / wrapping",
            bps: Math.round(bps * 0.15),
            level: "low",
            description: "Only canonical bridges accepted.",
          },
          {
            id: "sc",
            label: "Smart-contract surface",
            bps: Math.round(bps * 0.05),
            level: "low",
            description: "Standard ERC-20 implementations only.",
          },
        ]
      : [
          {
            id: "vol",
            label: "Realized volatility",
            bps: Math.round(bps * 0.5),
            level,
            description: "30d σ relative to the category's target band.",
          },
          {
            id: "oracle",
            label: "Oracle latency",
            bps: Math.round(bps * 0.2),
            level,
            description: "Chainlink feed + deviation guard.",
          },
          {
            id: "depth",
            label: "Liquidity depth",
            bps: Math.round(bps * 0.15),
            level: "low",
            description: "Depth across routing venues.",
          },
          {
            id: "sc",
            label: "Smart-contract surface",
            bps: Math.round(bps * 0.15),
            level: "low",
            description: "Token contract + wrapper if applicable.",
          },
        ],
    metrics: [
      { id: "category", label: "Category", value: asset.category === "stable" ? "Stablecoin" : "Volatile" },
      { id: "borrowApr", label: "Borrow APR", value: `${asset.borrowApr.toFixed(2)}%` },
      { id: "utilization", label: "Utilization", value: `${asset.utilization.toFixed(1)}%` },
      { id: "available", label: "Available", value: formatCompactUsd(asset.availableUsd) },
    ],
  }
}

const LEND_PREMIUM_BPS: Record<LendMarket["riskTier"], number> = { low: 32, medium: 95, high: 165 }

/** Full risk rating for a lend (single-asset supply) market, keyed off its risk tier. */
export function buildLendRiskAssessment(market: LendMarket): RiskAssessment {
  const bps = LEND_PREMIUM_BPS[market.riskTier]
  const level = riskLevelFromBps(bps)
  const isStable = market.riskTier === "low"
  return {
    premiumBps: bps,
    level,
    score: riskScoreFromBps(bps),
    headline: `${riskLevelLabel(level)} risk · ${formatBpsAsPct(bps)} premium`,
    summary: `${market.asset.name} is a single-asset supply market. Primary risks are ${isStable ? "a de-peg or issuer-solvency event" : "price volatility and withdrawal liquidity"} plus smart-contract surface; the reserve factor buffers supplier yield.`,
    breakdown: [
      {
        id: "asset",
        label: isStable ? "De-peg tail" : "Price volatility",
        bps: Math.round(bps * 0.45),
        level,
        description: isStable
          ? "Oracle deviation guardrails pause new supply on a sustained de-peg."
          : "30d realized volatility relative to the asset's risk tier.",
      },
      {
        id: "liquidity",
        label: "Withdrawal liquidity",
        bps: Math.round(bps * 0.25),
        level: "low",
        description: "Available liquidity vs. utilization; high utilization can delay withdrawals.",
      },
      {
        id: "sc",
        label: "Smart-contract surface",
        bps: Math.round(bps * 0.18),
        level: "low",
        description: "Supply vault + oracle dependencies, reviewed by the risk council.",
      },
      {
        id: "reserve",
        label: "Reserve coverage",
        bps: Math.max(2, Math.round(bps * 0.12)),
        level: "low",
        description: "The reserve factor accrues a protocol safety buffer from borrower interest.",
      },
    ],
    metrics: [
      {
        id: "riskTier",
        label: "Risk tier",
        value: market.riskTier === "low" ? "Low" : market.riskTier === "medium" ? "Medium" : "High",
      },
      { id: "supplyApy", label: "Supply APY", value: `${(market.supplyApy * 100).toFixed(2)}%` },
      { id: "utilization", label: "Utilization", value: `${(market.utilization * 100).toFixed(1)}%` },
      { id: "reserveFactor", label: "Reserve factor", value: `${(market.reserveFactor * 100).toFixed(0)}%` },
    ],
  }
}

/** Full risk rating for a multiply (leveraged loop) market, keyed off its leverage +
 *  collateral-factor settings. Shared by the Convex seed and the detail fallback. */
export function buildMultiplyRiskAssessment(market: MultiplyMarketRecord): RiskAssessment {
  const leverage = market.risk.publicMaxMultiplier
  const bps = Math.max(18, Math.round((leverage - 1) * 8 + (1 - market.risk.collateralFactor) * 120))
  const level = riskLevelFromBps(bps)
  return {
    premiumBps: bps,
    level,
    score: riskScoreFromBps(bps),
    headline: `${riskLevelLabel(level)} risk · ${formatBpsAsPct(bps)} premium`,
    summary: `${market.collateralAsset.symbol}/${market.borrowAsset.symbol} inherits leverage risk from the borrow leg and price-movement risk from the collateral leg.`,
    breakdown: [
      {
        id: "leverage",
        label: "Leverage",
        bps: Math.round(bps * 0.38),
        level,
        description: "Higher leverage magnifies both upside and liquidation speed.",
      },
      {
        id: "borrow",
        label: "Borrow APR",
        bps: Math.round(bps * 0.2),
        level: "low",
        description: "Borrow cost moves with utilization and market stress.",
      },
      {
        id: "collateral",
        label: "Collateral factor",
        bps: Math.round(bps * 0.2),
        level: "low",
        description: "The collateral leg sets how much buffer remains before liquidations.",
      },
      {
        id: "liquidity",
        label: "Available liquidity",
        bps: Math.round(bps * 0.12),
        level: "low",
        description: "Available capital limits how much of the market can be opened at once.",
      },
      {
        id: "spread",
        label: "Spread / slippage",
        bps: Math.max(2, Math.round(bps * 0.08)),
        level: "low",
        description: "Execution quality matters more as position size increases.",
      },
    ],
    metrics: [
      { id: "leverage", label: "Max leverage", value: `${market.risk.publicMaxMultiplier.toFixed(2)}x` },
      {
        id: "collateralFactor",
        label: "Collateral factor",
        value: `${Math.round(market.risk.collateralFactor * 100)}%`,
      },
      { id: "lt", label: "Liquidation threshold", value: `${Math.round(market.risk.liquidationThreshold * 100)}%` },
      { id: "liquidity", label: "Available", value: formatCompactUsd(market.economics.availableLiquidityUsd) },
    ],
  }
}

/** Full risk rating for an LP collateral pool. Premium comes from the catalog row. */
export function buildPoolRiskAssessment(row: BorrowPoolRow): RiskAssessment {
  const bps = row.riskPremiumBps
  const level = riskLevelFromBps(bps)
  const score = riskScoreFromBps(bps)
  return {
    premiumBps: bps,
    level,
    score,
    headline: `${riskLevelLabel(level)} risk · ${formatBpsAsPct(bps)} premium`,
    summary: `Risk premium is derived from pool volatility, depth, oracle latency, and spoke parameters (${getSpokeById(row.spoke).label}).`,
    breakdown: [
      {
        id: "vol",
        label: "Pair volatility",
        bps: Math.round(bps * 0.42),
        level,
        description: "Realized 30d σ relative to the spoke's target band.",
      },
      {
        id: "depth",
        label: "Liquidity depth",
        bps: Math.round(bps * 0.18),
        level: "low",
        description: "Depth at ±2% is above the spoke's liquidation threshold.",
      },
      {
        id: "oracle",
        label: "Oracle",
        bps: Math.round(bps * 0.22),
        level,
        description: "Primary oracle + deviation guard monitored by the risk council.",
      },
      {
        id: "sc",
        label: "Smart-contract surface",
        bps: Math.round(bps * 0.12),
        level: "low",
        description: "Source dex + LP wrapper audits reviewed quarterly.",
      },
      {
        id: "il",
        label: "Expected IL",
        bps: Math.max(2, Math.round(bps * 0.06)),
        level: "low",
        description: "Rolling 90d weekly impermanent loss for this tier.",
      },
    ],
    metrics: [
      {
        id: "dex",
        label: "Source dex",
        value: getDexById(row.dexes[0]?.id as Parameters<typeof getDexById>[0])?.label ?? row.venue,
      },
      { id: "spoke", label: "Spoke", value: getSpokeById(row.spoke).label },
      { id: "maxLtv", label: "Max LTV", value: formatPct(row.ltv, 0) },
      { id: "apr", label: "Supply APR range", value: aprRangeLabel(row) },
    ],
  }
}
