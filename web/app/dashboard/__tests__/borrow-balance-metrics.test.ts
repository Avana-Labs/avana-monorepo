import { describe, expect, it } from "vitest"
import { makeExampleBorrowSystemState } from "@/app/lib/borrow-system/model/__tests__/fixtures"
import { accrueBorrowSystemState, calculateCreditMetrics, usd6ToNumber } from "@/app/lib/borrow-system/model"
import {
  buildBorrowBalanceMetrics,
  buildBorrowDashboardMetricsFromSnapshot,
} from "@/app/dashboard/dashboard-tab-metrics"
import type { BorrowSnapshot } from "@/app/dashboard/borrow-hero-state"
import type { DebtRowContext, SupplyRowContext } from "@/app/lib/data/borrow-position-types"

describe("buildBorrowBalanceMetrics — wallet aggregate formulas", () => {
  it("exposes all 8 wallet-level Borrow Balance fields from the credit engine", () => {
    const state = makeExampleBorrowSystemState()
    const walletId = "wallet-1"
    const balance = buildBorrowBalanceMetrics(state, walletId, state.now)

    const metrics = calculateCreditMetrics(accrueBorrowSystemState(state, state.now), walletId)
    expect(balance.netValueUsd).toBeCloseTo(
      usd6ToNumber(metrics.poolCollateralValueUsd6 - metrics.totalBorrowedUsd6),
      6,
    )
    expect(balance.collateralValueUsd).toBeCloseTo(usd6ToNumber(metrics.poolCollateralValueUsd6), 6)
    expect(balance.totalBorrowedUsd).toBeCloseTo(usd6ToNumber(metrics.totalBorrowedUsd6), 6)
    expect(balance.availableToBorrowUsd).toBeCloseTo(usd6ToNumber(metrics.availableCreditUsd6), 6)
    expect(balance.healthFactor).not.toBeNull()
    expect(balance.healthFactor!).toBeCloseTo(Number(metrics.healthFactorWad) / 1e18, 6)
    expect(balance.liquidationBufferUsd).toBeCloseTo(
      usd6ToNumber(metrics.liquidationBufferUsd6 > 0n ? metrics.liquidationBufferUsd6 : 0n),
      6,
    )
    expect(balance.netApyPct).toBeCloseTo(
      (Number(metrics.annualYieldEarnedUsd6 - metrics.annualBorrowCostUsd6) /
        Number(metrics.poolCollateralValueUsd6 - metrics.totalBorrowedUsd6)) *
        100,
      6,
    )
    expect(balance.interestOwedUsd).toBeCloseTo(usd6ToNumber(metrics.interestOwedUsd6), 6)
  })

  it("returns null health factor and zero available when there is no debt and no collateral", () => {
    const state = makeExampleBorrowSystemState()
    const balance = buildBorrowBalanceMetrics(state, "wallet-2", state.now)
    expect(balance.totalBorrowedUsd).toBe(0)
    expect(balance.collateralValueUsd).toBe(0)
    expect(balance.availableToBorrowUsd).toBe(0)
    expect(balance.healthFactor).toBeNull()
    expect(balance.liquidationBufferUsd).toBeNull()
    expect(balance.interestOwedUsd).toBe(0)
  })

  it("does not count onboarding wallet cash or show liquidation risk before the first loan", () => {
    const state = makeExampleBorrowSystemState()
    const account = state.accounts["wallet-1"]!
    account.debtPositions = []
    account.walletBalanceUsd6 = 100_000_000_000n
    account.walletReturnedLpBalancesUsd6 = { "unused-lp": 25_000_000_000n }

    const balance = buildBorrowBalanceMetrics(state, "wallet-1", state.now)

    expect(balance.collateralValueUsd).toBeGreaterThan(0)
    expect(balance.netValueUsd).toBeCloseTo(balance.collateralValueUsd, 6)
    expect(balance.totalBorrowedUsd).toBe(0)
    expect(balance.healthFactor).toBeNull()
    expect(balance.liquidationBufferUsd).toBeNull()
  })

  it("available credit equals creditLimit − debt (never liquidation-threshold based)", () => {
    const state = makeExampleBorrowSystemState()
    const balance = buildBorrowBalanceMetrics(state, "wallet-1", state.now)
    const metrics = calculateCreditMetrics(accrueBorrowSystemState(state, state.now), "wallet-1")
    const creditLimit = usd6ToNumber(metrics.creditLimitUsd6)
    const debt = usd6ToNumber(metrics.totalBorrowedUsd6)
    expect(balance.availableToBorrowUsd).toBeCloseTo(Math.max(0, creditLimit - debt), 6)
    // Must be strictly less than or equal to liquidation buffer path when CF < LT.
    expect(balance.availableToBorrowUsd).toBeLessThanOrEqual(usd6ToNumber(metrics.liquidationValueUsd6) - debt + 1e-6)
  })
})

describe("buildBorrowDashboardMetricsFromSnapshot — Net APY formula", () => {
  const snapshot: BorrowSnapshot = {
    approvedUsd: 1_000,
    liquidationThresholdUsd: 8_200,
    totalBorrowedUsd: 4_000,
    totalCollateralUsd: 10_000,
    averageHealthFactor: 2.05,
    currentLtvPct: 40,
  }

  const supplies: SupplyRowContext[] = [
    {
      pool: {
        id: "a",
        name: "A",
        venue: "Uni",
        category: "",
        collateralUsd: 8_000,
        maxLtv: 70,
        borrowPowerUsd: 5_600,
        liquidationUsd: 6_560,
        pairApr: 10,
        visuals: [
          { symbol: "WETH", shortLabel: "W", bgClassName: "", textClassName: "" },
          { symbol: "USDC", shortLabel: "U", bgClassName: "", textClassName: "" },
        ],
      },
      borrowedUsd: 3_000,
      remainingBorrowPowerUsd: 2_600,
      liquidationThresholdUsd: 6_560,
      healthFactor: 2.1,
      pairApr: 10,
      feesUsd: 0,
      feesLabel: "$0",
    },
    {
      pool: {
        id: "b",
        name: "B",
        venue: "Curve",
        category: "",
        collateralUsd: 2_000,
        maxLtv: 70,
        borrowPowerUsd: 1_400,
        liquidationUsd: 1_640,
        pairApr: 4,
        visuals: [
          { symbol: "ETH", shortLabel: "E", bgClassName: "", textClassName: "" },
          { symbol: "USDT", shortLabel: "T", bgClassName: "", textClassName: "" },
        ],
      },
      borrowedUsd: 1_000,
      remainingBorrowPowerUsd: 400,
      liquidationThresholdUsd: 1_640,
      healthFactor: 1.6,
      pairApr: 4,
      feesUsd: 0,
      feesLabel: "$0",
    },
  ]

  const debts: DebtRowContext[] = [
    {
      id: "d1",
      pool: supplies[0]!.pool,
      debtAssetSymbol: "USDC",
      borrowedUsd: 3_000,
      liquidationThresholdUsd: 6_560,
      healthFactor: 2.1,
      borrowApr: 5,
      accruedInterestUsd: 12,
      dailyInterestUsd: 0.4,
    },
    {
      id: "d2",
      pool: supplies[1]!.pool,
      debtAssetSymbol: "USDT",
      borrowedUsd: 1_000,
      liquidationThresholdUsd: 1_640,
      healthFactor: 1.6,
      borrowApr: 6,
      accruedInterestUsd: 3,
      dailyInterestUsd: 0.16,
    },
  ]

  it("does not arithmetic-average position APYs", () => {
    const metrics = buildBorrowDashboardMetricsFromSnapshot(snapshot, supplies, debts)
    // Wrong (old) path: (10 + 4) / 2 = 7
    expect(metrics.performance.netApyPct).not.toBeCloseTo(7, 5)
  })

  it("computes equity-weighted (yield − borrow cost) / equity", () => {
    const metrics = buildBorrowDashboardMetricsFromSnapshot(snapshot, supplies, debts)
    // annual yield = 8000*0.10 + 2000*0.04 = 880
    // annual cost  = 3000*0.05 + 1000*0.06 = 210
    // equity       = 10000 − 4000 = 6000
    // net APY      = (880 − 210) / 6000 * 100 = 11.166...%
    expect(metrics.performance.netApyPct).toBeCloseTo(11.166666, 4)
    expect(metrics.performance.interestOwedUsd).toBeCloseTo(15, 6)
  })
})
