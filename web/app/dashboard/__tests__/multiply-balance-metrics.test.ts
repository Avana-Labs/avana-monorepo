import { describe, expect, it } from "vitest"
import { buildMockMultiplySystemState } from "@/app/lib/multiply-system/mock"
import { buildPortfolioMultiplyData } from "@/app/lib/multiply-system/read-model"
import { buildMultiplyBalanceMetrics } from "@/app/dashboard/dashboard-tab-metrics"
import type { MultiplyPosition } from "@/app/lib/multiply-engine"

const WALLET = "mult-balance-wallet"

function position(
  id: string,
  marketId: string,
  collateralUsd: number,
  debtUsd: number,
  netApy: number,
  healthFactor: number,
): MultiplyPosition {
  return {
    id,
    walletId: WALLET,
    marketId,
    collateralAmount: collateralUsd,
    collateralValueUsd: collateralUsd,
    debtValueUsd: debtUsd,
    multiplier: collateralUsd / Math.max(1, collateralUsd - debtUsd),
    ltv: debtUsd / collateralUsd,
    healthFactor,
    liquidationPrice: null,
    netApy,
    openedAt: 0,
    lastUpdatedAt: 0,
  }
}

describe("buildMultiplyBalanceMetrics — wallet aggregate formulas", () => {
  it("exposes Position Value, Leverage, combined Health Factor, and equity-weighted Net APY", () => {
    const state = buildMockMultiplySystemState(WALLET)
    const markets = Object.keys(state.markets)
    state.positions = {
      a: position("a", markets[0]!, 1_000, 500, 0.1, 3.0),
      b: position("b", markets[1] ?? markets[0]!, 3_000, 1_500, 0.02, 1.2),
    }
    const tab = buildPortfolioMultiplyData(WALLET, state, [])
    const balance = buildMultiplyBalanceMetrics(state, WALLET, tab)

    // Position Value = gross collateral sum
    expect(balance.positionValueUsd).toBeCloseTo(4_000, 6)
    // Net Value = equity
    expect(balance.netValueUsd).toBeCloseTo(2_000, 6)
    expect(balance.totalBorrowedUsd).toBeCloseTo(2_000, 6)
    // Leverage = gross / equity = 2
    expect(balance.leverageX).toBeCloseTo(2, 6)
    // Equity-weighted Net APY (not flat mean 6%)
    expect(balance.netApyPct).toBeCloseTo(4, 6)
    // Combined HF = liquidationThreshold / debt — NOT min(3.0, 1.2) = 1.2
    expect(balance.healthFactor).not.toBeNull()
    expect(balance.healthFactor!).toBeCloseTo(tab.creditLines.liquidationThresholdUsd / 2_000, 6)
    expect(balance.healthFactor!).not.toBeCloseTo(1.2, 5)
    expect(balance.liquidationBufferUsd).toBeCloseTo(Math.max(0, tab.creditLines.liquidationThresholdUsd - 2_000), 6)
  })

  it("handles zero debt safely (null HF, 1× leverage when only equity)", () => {
    const state = buildMockMultiplySystemState(WALLET)
    const marketId = Object.keys(state.markets)[0]!
    state.positions = {
      a: position("a", marketId, 5_000, 0, 0.05, Number.POSITIVE_INFINITY),
    }
    const tab = buildPortfolioMultiplyData(WALLET, state, [])
    const balance = buildMultiplyBalanceMetrics(state, WALLET, tab)
    expect(balance.healthFactor).toBeNull()
    expect(balance.totalBorrowedUsd).toBe(0)
    expect(balance.leverageX).toBeCloseTo(1, 6)
    expect(balance.netValueUsd).toBeCloseTo(5_000, 6)
    expect(balance.positionValueUsd).toBeCloseTo(5_000, 6)
  })

  it("returns zeros for an empty wallet", () => {
    const state = buildMockMultiplySystemState(WALLET)
    state.positions = {}
    const tab = buildPortfolioMultiplyData(WALLET, state, [])
    const balance = buildMultiplyBalanceMetrics(state, WALLET, tab)
    expect(balance).toEqual({
      netValueUsd: 0,
      positionValueUsd: 0,
      totalBorrowedUsd: 0,
      leverageX: 0,
      netApyPct: 0,
      healthFactor: null,
      liquidationBufferUsd: 0,
      riskPremiumPct: 0,
      interestEarnedUsd: 0,
      interestPerYearUsd: 0,
      accrualSinceMs: expect.any(Number),
    })
  })
})
