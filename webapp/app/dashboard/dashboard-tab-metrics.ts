import { calculateCreditMetrics, clampNetApyWad, usd6ToNumber } from "@/app/lib/borrow-system/model"
import type { BorrowSystemState } from "@/app/lib/borrow-system/model"
import { lendNetApyPct } from "@/app/lib/lend-system/read-model"
import type { DebtRowContext, SupplyRowContext } from "@/app/lib/data/borrow-position-types"
import type { BorrowSnapshot } from "@/app/dashboard/borrow-hero-state"
import type { PortfolioLendTabData } from "@/app/lib/data/providers/portfolio"

type DashboardOverviewMetrics = {
  netValueUsd: number
  totalBorrowedUsd: number
  liquidationBufferUsd: number
  riskPremiumPct: number
}

type DashboardPerformanceMetrics = {
  poolCollateralUsd: number
  netApyPct: number
  interestEarnedUsd: number
  interestOwedUsd: number
}

type DashboardTabMetrics = {
  overview: DashboardOverviewMetrics
  performance: DashboardPerformanceMetrics
}

/** Canonical wallet-level Borrow Balance snapshot. */
export type BorrowBalanceMetrics = {
  netValueUsd: number
  collateralValueUsd: number
  totalBorrowedUsd: number
  availableToBorrowUsd: number
  healthFactor: number | null
  liquidationBufferUsd: number | null
  netApyPct: number
  interestOwedUsd: number
  /**
   * Debt interest accruing per year (Σ debt × borrow APY) plus the snapshot moment
   * `interestOwedUsd` is accrued to — together they drive the live Interest Owed counter, which
   * ticks up from the current amount. Optional: the snapshot/loading fallback omits them and the
   * figure stays static.
   */
  interestOwedPerYearUsd?: number
  accrualSinceMs?: number
}

const WAD = 10n ** 18n
const YEAR_MS = 365 * 24 * 60 * 60 * 1000

function wadToPct(value: bigint) {
  return (Number(value) / Number(WAD)) * 100
}

function wadToNumber(value: bigint) {
  return Number(value) / Number(WAD)
}

/**
 * Snapshot-path Net APY: (Σ collateral×pairApr − Σ debt×borrowApr) / equity.
 * Never arithmetic-averages position APYs — that misstates multi-position wallets.
 */
export function estimateBorrowNetApyPctFromRows(
  totalCollateralUsd: number,
  totalBorrowedUsd: number,
  collateralPositions: SupplyRowContext[],
  debtPositions: DebtRowContext[],
): number {
  const equityUsd = totalCollateralUsd - totalBorrowedUsd
  if (equityUsd <= 0) return 0
  const annualYieldUsd = collateralPositions.reduce((sum, row) => sum + row.pool.collateralUsd * (row.pairApr / 100), 0)
  const annualCostUsd = debtPositions.reduce((sum, row) => sum + row.borrowedUsd * (row.borrowApr / 100), 0)
  return ((annualYieldUsd - annualCostUsd) / equityUsd) * 100
}

export function buildBorrowDashboardMetricsFromSnapshot(
  snapshot: BorrowSnapshot,
  collateralPositions: SupplyRowContext[] = [],
  debtPositions: DebtRowContext[] = [],
): DashboardTabMetrics {
  const totalCollateralUsd = snapshot.totalCollateralUsd
  const totalBorrowedUsd = snapshot.totalBorrowedUsd
  const interestEarnedUsd = collateralPositions.reduce((sum, row) => sum + row.feesUsd, 0)
  const interestOwedUsd = debtPositions.reduce((sum, row) => sum + row.accruedInterestUsd, 0)
  const netApyPct = estimateBorrowNetApyPctFromRows(
    totalCollateralUsd,
    totalBorrowedUsd,
    collateralPositions,
    debtPositions,
  )

  return {
    overview: {
      netValueUsd: totalCollateralUsd - totalBorrowedUsd,
      totalBorrowedUsd,
      liquidationBufferUsd: Math.max(0, snapshot.liquidationThresholdUsd - totalBorrowedUsd),
      riskPremiumPct: 0,
    },
    performance: {
      poolCollateralUsd: totalCollateralUsd,
      netApyPct,
      interestEarnedUsd,
      interestOwedUsd,
    },
  }
}

/**
 * Single aggregation pass over the credit engine for the wallet's Borrow Balance.
 * Available to Borrow uses collateral-factor credit limit − debt (protocol capacity),
 * never a liquidation-threshold heuristic. Health Factor is wallet-wide
 * liquidationValue / totalBorrowed (null when debt-free).
 */
export function buildBorrowBalanceMetrics(
  state: BorrowSystemState,
  walletId: string,
  now: number = Date.now(),
): BorrowBalanceMetrics {
  const accrued = state
  const metrics = calculateCreditMetrics(accrued, walletId)
  const netPositionValueUsd6 = metrics.poolCollateralValueUsd6 - metrics.totalBorrowedUsd6
  const rawNetApyWad =
    netPositionValueUsd6 > 0n
      ? ((metrics.annualYieldEarnedUsd6 - metrics.annualBorrowCostUsd6) * WAD) / netPositionValueUsd6
      : 0n

  // Interest Owed as a per-position display, accrued from each debt's own `openedAt`, NOT the
  // engine index. The index only advances while the app
  // computes on read and shares one account clock, so any action reset every loan's interest to ~0.
  // Debt × its borrow rate × (now − openedAt). The engine's index-based debt VALUE (health factor,
  // borrow power) is deliberately left untouched — this is the display/ticker figure only.
  const debtPositions = accrued.accounts[walletId]?.debtPositions ?? []
  let interestOwedUsd = 0
  let interestOwedPerYearUsd = 0
  for (const debt of debtPositions) {
    const principalUsd = usd6ToNumber(debt.principalBorrowedUsd6)
    const ratePerYear = Number(debt.borrowRateWad) / Number(WAD)
    const perYearUsd = principalUsd * ratePerYear
    interestOwedPerYearUsd += perYearUsd
    interestOwedUsd += perYearUsd * (Math.max(0, now - (debt.openedAt ?? now)) / YEAR_MS)
  }

  return {
    // Borrow Balance is protocol-position equity. The account's liquid wallet balance
    // is shown separately on the dashboard and must not be counted again here.
    netValueUsd: usd6ToNumber(netPositionValueUsd6),
    collateralValueUsd: usd6ToNumber(metrics.poolCollateralValueUsd6),
    totalBorrowedUsd: usd6ToNumber(metrics.totalBorrowedUsd6),
    availableToBorrowUsd: usd6ToNumber(metrics.availableCreditUsd6),
    healthFactor: metrics.totalBorrowedUsd6 > 0n ? wadToNumber(metrics.healthFactorWad) : null,
    liquidationBufferUsd:
      metrics.totalBorrowedUsd6 > 0n
        ? usd6ToNumber(metrics.liquidationBufferUsd6 > 0n ? metrics.liquidationBufferUsd6 : 0n)
        : null,
    netApyPct: wadToPct(clampNetApyWad(rawNetApyWad)),
    interestOwedUsd,
    // Live Interest Owed ticks up from `interestOwedUsd` (accrued to `now`) at this per-year rate.
    interestOwedPerYearUsd,
    accrualSinceMs: now,
  }
}

export function buildLendDashboardMetrics(data: PortfolioLendTabData) {
  const balance = buildLendBalanceMetrics(data)
  const investments = data.investments ?? []
  const rewardsEarnedUsd = investments.reduce((sum, item) => sum + (item.rewardsEarnedUsd ?? 0), 0)
  const claimableRewardsUsd = data.rewardsSummary?.claimableUsd ?? 0

  return {
    totalSuppliedUsd: balance.totalSuppliedUsd,
    netApyPct: balance.netApyPct,
    interestEarnedUsd: balance.interestEarnedUsd,
    rewardsEarnedUsd,
    claimableRewardsUsd,
  }
}

/** Canonical wallet-level Lend Balance snapshot (8 growth-focused metrics). */
export type LendBalanceMetrics = {
  totalSuppliedUsd: number
  netApyPct: number
  interestEarnedUsd: number
  /** Interest earned ÷ principal supplied, as a percent. */
  yieldGeneratedPct: number
  projectedEarnings1dUsd: number
  projectedEarnings30dUsd: number
  projectedEarnings90dUsd: number
  projectedEarnings6mUsd: number
  /**
   * When supply started (earliest supply tx), for the real-time Interest Earned / Yield
   * Generated counters to accrue from. `null` when there is no supply history to anchor on.
   */
  accrualSinceMs: number | null
}

const LEND_PROJECTION_HORIZONS_DAYS = {
  d1: 1,
  d30: 30,
  d90: 90,
  /** Half-year using 182.5 days so 6M ≈ half of a 365-day year. */
  m6: 182.5,
} as const

/**
 * Simple forward earnings for one position — matches lend-engine / Ask AI accrual
 * (linear in time), not compound (1+apy)^(t/365).
 */
export function projectLendSimpleEarningsUsd(suppliedUsd: number, apyPct: number, days: number): number {
  if (!(suppliedUsd > 0) || !Number.isFinite(apyPct) || !(days > 0)) return 0
  return suppliedUsd * (apyPct / 100) * (days / 365)
}

/**
 * Portfolio projected earnings: Σ per-position simple projections.
 * Equivalent to TotalSupplied × NetAPY × (days/365) when Net APY is supplied-weighted.
 */
export function projectLendPortfolioEarningsUsd(
  investments: ReadonlyArray<{ suppliedUsd: number; apyPct: number }>,
  days: number,
): number {
  return investments.reduce((sum, item) => sum + projectLendSimpleEarningsUsd(item.suppliedUsd, item.apyPct, days), 0)
}

/**
 * Yield Generated = Interest Earned / Principal Supplied.
 * Principal prefers engine principalUsd (deposits − withdrawn principal), not current
 * Total Supplied (which already includes accrued interest).
 */
export function lendYieldGeneratedPct(
  interestEarnedUsd: number,
  investments: ReadonlyArray<{ suppliedUsd: number; principalUsd?: number; interestUsd?: number; earnedUsd?: number }>,
): number {
  const principalUsd = investments.reduce((sum, item) => {
    if (item.principalUsd != null && Number.isFinite(item.principalUsd)) {
      return sum + Math.max(0, item.principalUsd)
    }
    const interest = item.interestUsd ?? Math.max(0, (item.earnedUsd ?? 0) - 0)
    return sum + Math.max(0, item.suppliedUsd - interest)
  }, 0)
  if (!(principalUsd > 0) || !Number.isFinite(interestEarnedUsd)) return 0
  return (interestEarnedUsd / principalUsd) * 100
}

/**
 * Single aggregation pass for the Lend Balance dashboard.
 * Rewards remain available via buildLendDashboardMetrics for Claim UI — not on these cards.
 */
export function buildLendBalanceMetrics(data: PortfolioLendTabData): LendBalanceMetrics {
  const investments = data.investments ?? []
  const totalSuppliedUsd = investments.reduce((sum, item) => sum + item.suppliedUsd, 0)
  const netApyPct = lendNetApyPct(investments)
  const interestEarnedUsd = investments.reduce(
    (sum, item) => sum + (item.interestUsd ?? item.earnedUsd - (item.rewardsEarnedUsd ?? 0)),
    0,
  )
  const yieldGeneratedPct = lendYieldGeneratedPct(interestEarnedUsd, investments)

  // Anchor the live counters at the earliest supply so interest accrues from when funds were
  // actually supplied (not from page load, which would start every counter at $0).
  const supplyStartMs = (data.history ?? [])
    .filter((row) => row.kind === "supply")
    .map((row) => Date.parse(row.at))
    .filter((ms) => Number.isFinite(ms) && ms > 0)
  const accrualSinceMs = supplyStartMs.length > 0 ? Math.min(...supplyStartMs) : null

  return {
    totalSuppliedUsd,
    netApyPct,
    interestEarnedUsd,
    yieldGeneratedPct,
    projectedEarnings1dUsd: projectLendPortfolioEarningsUsd(investments, LEND_PROJECTION_HORIZONS_DAYS.d1),
    projectedEarnings30dUsd: projectLendPortfolioEarningsUsd(investments, LEND_PROJECTION_HORIZONS_DAYS.d30),
    projectedEarnings90dUsd: projectLendPortfolioEarningsUsd(investments, LEND_PROJECTION_HORIZONS_DAYS.d90),
    projectedEarnings6mUsd: projectLendPortfolioEarningsUsd(investments, LEND_PROJECTION_HORIZONS_DAYS.m6),
    accrualSinceMs,
  }
}
