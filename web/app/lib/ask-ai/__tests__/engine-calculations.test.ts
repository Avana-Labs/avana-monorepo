import { describe, expect, it } from "vitest"
import {
  askAIHealthFactorValue,
  askAIRiskLevel,
  calculateAskAIBorrowSimulation,
  calculateAskAICollateralStress,
  calculateBorrowProjection,
  calculateLendProjection,
  calculateMultiplyStress,
  decodeBorrowRiskSnapshot,
  deriveAskAIUmbrellaStatus,
} from "../engine-calculations"

describe("Ask AI engine calculations", () => {
  it("simulates an exact additional borrow with deterministic risk values", () => {
    expect(
      calculateAskAIBorrowSimulation({
        collateralValueUsd: 10_000,
        debtValueUsd: 3_500,
        additionalBorrowAmountUsd: 1_000,
        maxLtvPct: 55,
        liquidationThresholdPct: 65,
      }),
    ).toMatchObject({
      current: { ltv: 0.35, healthFactor: 1.8571428571428572 },
      projected: { debtValueUsd: 4_500, ltv: 0.45, healthFactor: 1.4444444444444444 },
      remainingBorrowCapacityUsd: 1_000,
      overMaxBorrowLtv: false,
      liquidatable: false,
      riskLevel: "elevated",
    })
  })

  it("applies requested asset shocks to weighted LP collateral", () => {
    expect(
      calculateAskAICollateralStress({
        collateralValueUsd: 10_000,
        debtValueUsd: 4_000,
        liquidationThresholdPct: 65,
        constituents: [
          { symbol: "ETH", weight: 0.5 },
          { symbol: "USDC", weight: 0.5 },
        ],
        assetPriceChanges: { ETH: -0.2 },
      }),
    ).toMatchObject({
      weightedCollateralChange: -0.1,
      projected: { collateralValueUsd: 9_000, ltv: 4_000 / 9_000, healthFactor: 1.4625 },
      liquidatable: false,
    })
  })

  it("decodes Credit Engine fixed-point risk without changing units", () => {
    expect(
      decodeBorrowRiskSnapshot({
        collateralValueUsd6: "100000000",
        borrowCapacityUsd6: "70000000",
        availableBorrowCapacityUsd6: "20000000",
        totalBorrowedUsd6: "50000000",
        currentLtvWad: "500000000000000000",
        healthFactorWad: "1400000000000000000",
      }),
    ).toEqual({
      collateralValueUsd: 100,
      borrowCapacityUsd: 70,
      availableBorrowCapacityUsd: 20,
      totalBorrowedUsd: 50,
      currentLtv: 0.5,
      healthFactor: 1.4,
    })
  })

  it("uses the Lend Engine for a 30-day yield projection", () => {
    expect(calculateLendProjection({ principalUsd: 10_000, supplyApyPct: 4, rewardsApyPct: 1, days: 30 })).toEqual({
      totalApyPct: 5,
      projectedYieldUsd: 10_000 * 0.05 * (30 / 365),
      days: 30,
    })
  })

  it("uses the Multiply Engine to stress health after a collateral shock", () => {
    expect(
      calculateMultiplyStress({
        collateralValueUsd: 2_000,
        debtValueUsd: 1_000,
        liquidationThresholdPct: 80,
        collateralPriceShockPct: -20,
      }),
    ).toEqual({
      collateralPriceShockPct: -20,
      shockedCollateralValueUsd: 1_600,
      ltv: 0.625,
      healthFactor: 1.28,
      // The loss in dollars and the risk wording are returned so the model
      // never subtracts collateral values or invents a severity itself.
      collateralLossUsd: 400,
      riskLevel: "elevated",
    })
  })

  it("derives Umbrella lifecycle state from persisted cooldown fields", () => {
    expect(
      deriveAskAIUmbrellaStatus({
        status: "open",
        suppliedUsd6: "100000000",
        cooldownAmountUsd6: "25000000",
        cooldownEndsAt: 2_000,
        now: 1_000,
      }),
    ).toBe("partiallyCooling")
  })
})

describe("Ask AI answer scalars", () => {
  it("treats no debt as safe and never leaks the string health factor", () => {
    expect(askAIRiskLevel("infinity")).toBe("low")
    expect(askAIRiskLevel(null)).toBe("none")
    expect(askAIRiskLevel(0.9)).toBe("critical")
    expect(askAIRiskLevel(1.2)).toBe("elevated")
    expect(askAIRiskLevel(3)).toBe("low")
    expect(askAIHealthFactorValue("infinity")).toMatchObject({ healthFactor: null, noDebt: true, riskLevel: "low" })
    expect(askAIHealthFactorValue(1.25)).toMatchObject({
      healthFactor: 1.25,
      noDebt: false,
      healthFactorHeadroom: 0.25,
    })
  })

  it("projects borrow interest over a window", () => {
    expect(calculateBorrowProjection({ debtUsd: 10_000, borrowAprPct: 5, days: 365 })).toMatchObject({
      projectedInterestUsd: 500,
      days: 365,
    })
    expect(calculateBorrowProjection({ debtUsd: 10_000, borrowAprPct: 5, days: 0 }).projectedInterestUsd).toBe(0)
  })
})
