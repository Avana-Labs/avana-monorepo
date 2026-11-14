import { describe, expect, it } from "vitest"
import { buildMockMultiplySystemState } from "@/app/lib/multiply-system/mock"
import { buildMultiplyWalletSnapshot } from "@/app/lib/multiply-system/read-model"
import type { MultiplyPosition } from "@/app/lib/multiply-engine"

const WALLET = "blend-wallet"

function position(
  id: string,
  marketId: string,
  collateralUsd: number,
  debtUsd: number,
  netApy: number,
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
    healthFactor: 2,
    liquidationPrice: null,
    netApy,
    openedAt: 0,
    lastUpdatedAt: 0,
  }
}

describe("buildMultiplyWalletSnapshot blended metrics (#21)", () => {
  it("equity-weights net APY and reports true portfolio leverage", () => {
    const state = buildMockMultiplySystemState(WALLET)
    const markets = Object.keys(state.markets)
    state.positions = {
      a: position("a", markets[0], 1_000, 500, 0.1), // equity 500
      b: position("b", markets[1] ?? markets[0], 3_000, 1_500, 0.02), // equity 1500
    }

    const { metrics } = buildMultiplyWalletSnapshot(WALLET, state, [])

    // Equity-weighted: (0.10·500 + 0.02·1500) / 2000 = 0.04 — NOT the flat mean 0.06.
    expect(metrics.netApy).toBeCloseTo(0.04, 6)
    // Portfolio leverage = total collateral / total equity = 4000 / 2000 = 2.
    expect(metrics.multiplier).toBeCloseTo(2, 6)
  })
})
