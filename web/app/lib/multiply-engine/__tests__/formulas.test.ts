import { describe, expect, it } from "vitest"
import {
  calculateLiquidationPrice,
  calculateMultiplyHealthFactor,
  calculateMultiplyLtv,
  calculateNetApy,
  calculateSafeMaxMultiplier,
  calculateTheoreticalMaxMultiplier,
  simulateCollateralLoop,
} from "@/app/lib/multiply-engine"

describe("multiply engine formulas", () => {
  it("calculates theoretical max multiplier", () => {
    expect(calculateTheoreticalMaxMultiplier(0.73)).toBeCloseTo(3.7037, 3)
  })

  it("calculates safe max multiplier", () => {
    const theoretical = calculateTheoreticalMaxMultiplier(0.73)
    expect(
      calculateSafeMaxMultiplier({
        publicMaxMultiplier: 2.2,
        theoreticalMaxMultiplier: theoretical,
        minHealthFactor: 1.3,
        liquidationThreshold: 0.8,
      }),
    ).toBeCloseTo(2.2, 5)
  })

  it("iterates collateral loops toward a target multiplier", () => {
    const initialCollateralValueUsd = 3500
    const selectedMultiplier = 2.5
    const maxLtv = 0.73
    const loop = simulateCollateralLoop({
      initialCollateralUsd: initialCollateralValueUsd,
      targetMultiplier: selectedMultiplier,
      maxLtv,
      swapEfficiency: 0.998,
    })

    const ltv = calculateMultiplyLtv(loop.debtUsd, loop.collateralUsd)
    const healthFactor = calculateMultiplyHealthFactor(loop.collateralUsd, loop.debtUsd, 0.8)
    const liquidationPrice = calculateLiquidationPrice({
      debtValueUsd: loop.debtUsd,
      collateralAmount: loop.collateralUsd / 3500,
      liquidationThreshold: 0.8,
    })
    const netApy = calculateNetApy({
      supplyApy: 0.0382,
      borrowApy: 0.039,
      finalCollateralValueUsd: loop.collateralUsd,
      debtValueUsd: loop.debtUsd,
      initialCollateralValueUsd,
    })

    expect(loop.loops).toBeGreaterThan(0)
    expect(loop.achievedMultiplier).toBeCloseTo(selectedMultiplier, 1)
    expect(loop.collateralUsd).toBeGreaterThan(initialCollateralValueUsd)
    expect(loop.debtUsd).toBeGreaterThan(0)
    expect(ltv).toBeLessThanOrEqual(maxLtv + 0.01)
    expect(healthFactor).toBeGreaterThan(1)
    expect(liquidationPrice).toBeGreaterThan(0)
    expect(netApy).toBeGreaterThan(0)
  })
})
