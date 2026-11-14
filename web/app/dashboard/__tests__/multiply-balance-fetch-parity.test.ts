import { describe, expect, it } from "vitest"
import { buildMockMultiplySystemState } from "@/app/lib/multiply-system/mock"
import { buildPortfolioMultiplyData, buildMultiplyWalletSnapshot } from "@/app/lib/multiply-system/read-model"
import { buildMultiplyBalanceMetrics } from "@/app/dashboard/dashboard-tab-metrics"
import type { MultiplyPosition } from "@/app/lib/multiply-engine"

const WALLET = "fetch-parity-wallet"

describe("Multiply Balance fetching parity", () => {
  it("Position Value and Leverage agree with portfolio + wallet snapshots", () => {
    const state = buildMockMultiplySystemState(WALLET)
    const marketId = Object.keys(state.markets)[0]!
    state.positions = {
      a: {
        id: "a",
        walletId: WALLET,
        marketId,
        collateralAmount: 9_000,
        collateralValueUsd: 9_000,
        debtValueUsd: 6_000,
        multiplier: 3,
        ltv: 6_000 / 9_000,
        healthFactor: 1.4,
        liquidationPrice: null,
        netApy: 0.07,
        openedAt: 0,
        lastUpdatedAt: 0,
      } satisfies MultiplyPosition,
    }

    const tab = buildPortfolioMultiplyData(WALLET, state, [])
    const balance = buildMultiplyBalanceMetrics(state, WALLET, tab)
    const wallet = buildMultiplyWalletSnapshot(WALLET, state, [])

    expect(balance.positionValueUsd).toBeCloseTo(tab.creditLines.totalCollateralUsd, 6)
    expect(balance.totalBorrowedUsd).toBeCloseTo(tab.creditLines.totalBorrowedUsd, 6)
    expect(balance.leverageX).toBeCloseTo(wallet.metrics.multiplier, 6)
    expect(balance.netApyPct).toBeCloseTo(wallet.metrics.netApy * 100, 6)
    // Combined HF (not worst-of-one here, but still liqThreshold/debt)
    expect(balance.healthFactor).toBeCloseTo(tab.creditLines.liquidationThresholdUsd / 6_000, 6)
  })
})
