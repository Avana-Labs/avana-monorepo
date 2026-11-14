import { describe, expect, it } from "vitest"
import {
  calculateLoopSteps,
  calculateMaxLeverageApy,
  calculatePriceImpact,
  calculateTheoreticalMaxMultiplier,
  simulateCollateralLoop,
} from "@/app/lib/multiply-engine"
import { validateDeleverageAction, validateMultiplyAction } from "@/app/lib/multiply-engine/validation"

describe("multiply engine validation", () => {
  it("warns when multiply exceeds the theoretical maximum", () => {
    const theoreticalMax = calculateTheoreticalMaxMultiplier(0.5)
    const result = validateMultiplyAction({
      selectedMultiplier: 3,
      theoreticalMaxMultiplier: theoreticalMax,
      publicMaxMultiplier: 5,
      safeMaxMultiplier: 4,
      recommendedMaxMultiplier: 3.5,
      minHealthFactor: 1.5,
      maxLtv: 0.5,
      healthFactor: 2.1,
      ltv: 0.4,
      debtValueUsd: 2500,
      initialCollateralValueUsd: 3500,
      priceImpactPct: 0.002,
      maxAllowedPriceImpact: 0.01,
      netApy: 0.03,
      supplyApy: 0.076,
      borrowApy: 0.039,
      liquidationPrice: 2100,
      collateralPriceUsd: 280,
    })

    expect(result.allowed).toBe(true)
    expect(result.warnings.join(" ")).toContain("theoretical maximum")
  })

  it("blocks multiply actions above the public maximum", () => {
    const theoreticalMax = calculateTheoreticalMaxMultiplier(0.73)
    const result = validateMultiplyAction({
      selectedMultiplier: 3,
      theoreticalMaxMultiplier: theoreticalMax,
      publicMaxMultiplier: 2.2,
      safeMaxMultiplier: 2.2,
      recommendedMaxMultiplier: 2,
      minHealthFactor: 1.3,
      maxLtv: 0.73,
      healthFactor: 1.4,
      ltv: 0.5,
      debtValueUsd: 2500,
      initialCollateralValueUsd: 3500,
      priceImpactPct: 0.002,
      maxAllowedPriceImpact: 0.01,
      netApy: 0.03,
      supplyApy: 0.0382,
      borrowApy: 0.039,
      liquidationPrice: 2100,
      collateralPriceUsd: 3500,
    })

    expect(result.allowed).toBe(false)
    expect(result.errors.join(" ")).toContain("public maximum")
  })

  it("blocks multiply when health factor is below the liquidation threshold", () => {
    const theoreticalMax = calculateTheoreticalMaxMultiplier(0.5)
    const result = validateMultiplyAction({
      selectedMultiplier: 3,
      theoreticalMaxMultiplier: theoreticalMax,
      publicMaxMultiplier: 20,
      safeMaxMultiplier: 1.8,
      recommendedMaxMultiplier: 1.6,
      minHealthFactor: 1.5,
      maxLtv: 0.5,
      healthFactor: 0.97,
      ltv: 0.67,
      debtValueUsd: 2500,
      initialCollateralValueUsd: 3500,
      priceImpactPct: 0.002,
      maxAllowedPriceImpact: 0.01,
      netApy: 0.03,
      supplyApy: 0.076,
      borrowApy: 0.039,
      liquidationPrice: 2100,
      collateralPriceUsd: 280,
    })

    expect(result.allowed).toBe(false)
    expect(result.errors.join(" ")).toContain("liquidation threshold")
  })

  it("blocks multiply when LTV exceeds the market maximum", () => {
    const theoreticalMax = calculateTheoreticalMaxMultiplier(0.5)
    const result = validateMultiplyAction({
      selectedMultiplier: 3,
      theoreticalMaxMultiplier: theoreticalMax,
      publicMaxMultiplier: 20,
      safeMaxMultiplier: 1.8,
      recommendedMaxMultiplier: 1.6,
      minHealthFactor: 1.5,
      maxLtv: 0.5,
      healthFactor: 2.1,
      ltv: 0.67,
      debtValueUsd: 2500,
      initialCollateralValueUsd: 3500,
      priceImpactPct: 0.002,
      maxAllowedPriceImpact: 0.01,
      netApy: 0.03,
      supplyApy: 0.076,
      borrowApy: 0.039,
      liquidationPrice: 2100,
      collateralPriceUsd: 280,
    })

    expect(result.allowed).toBe(false)
    expect(result.errors.join(" ")).toContain("LTV exceeds the market maximum")
  })

  it("blocks multiply when health factor is between 1.0 and the market minimum", () => {
    const theoreticalMax = calculateTheoreticalMaxMultiplier(0.8)
    const result = validateMultiplyAction({
      selectedMultiplier: 3,
      theoreticalMaxMultiplier: theoreticalMax,
      publicMaxMultiplier: 20,
      safeMaxMultiplier: 4,
      recommendedMaxMultiplier: 3.5,
      minHealthFactor: 1.5,
      maxLtv: 0.8,
      // Solvent (HF > 1.0) but below the market's 1.5 minimum -> must hard-block.
      healthFactor: 1.2,
      ltv: 0.6,
      debtValueUsd: 2500,
      initialCollateralValueUsd: 3500,
      priceImpactPct: 0.002,
      maxAllowedPriceImpact: 0.01,
      netApy: 0.03,
      supplyApy: 0.076,
      borrowApy: 0.039,
      liquidationPrice: 2100,
      collateralPriceUsd: 280,
    })

    expect(result.allowed).toBe(false)
    expect(result.errors.join(" ")).toContain("market minimum")
  })

  it("warns when multiply exceeds the recommended maximum", () => {
    const theoreticalMax = calculateTheoreticalMaxMultiplier(0.9)
    const result = validateMultiplyAction({
      selectedMultiplier: 4.8,
      theoreticalMaxMultiplier: theoreticalMax,
      publicMaxMultiplier: 5,
      safeMaxMultiplier: 4.5,
      recommendedMaxMultiplier: 4.2,
      minHealthFactor: 1.15,
      maxLtv: 0.9,
      healthFactor: 1.6,
      ltv: 0.55,
      debtValueUsd: 9000,
      initialCollateralValueUsd: 5000,
      priceImpactPct: 0.003,
      maxAllowedPriceImpact: 0.01,
      netApy: 0.04,
      supplyApy: 0.0514,
      borrowApy: 0.04,
      liquidationPrice: 1800,
      collateralPriceUsd: 3800,
    })

    expect(result.allowed).toBe(true)
    expect(result.warnings.join(" ")).toContain("recommended maximum")
  })

  it("blocks deleverage targets that do not reduce multiplier", () => {
    const result = validateDeleverageAction({
      targetMultiplier: 2.5,
      currentMultiplier: 2.5,
      targetDebtValueUsd: 4000,
      currentDebtValueUsd: 4000,
      newHealthFactor: 1.8,
      minHealthFactor: 1.2,
      priceImpactPct: 0.001,
      maxAllowedPriceImpact: 0.01,
    })

    expect(result.allowed).toBe(false)
    expect(result.errors.join(" ")).toContain("lower than the current multiplier")
  })
})

describe("multiply engine formulas extensions", () => {
  it("calculates loop steps from max LTV and target multiplier", () => {
    expect(calculateLoopSteps(0.73, 4)).toBeGreaterThan(1)
    expect(calculateLoopSteps(1, 3)).toBe(0)
  })

  it("simulates iterative collateral loops", () => {
    const loop = simulateCollateralLoop({
      initialCollateralUsd: 10_000,
      targetMultiplier: 3,
      maxLtv: 0.8,
      swapEfficiency: 0.995,
    })

    expect(loop.loops).toBeGreaterThan(1)
    expect(loop.achievedMultiplier).toBeCloseTo(3, 1)
    expect(loop.collateralUsd / (loop.collateralUsd - loop.debtUsd)).toBeCloseTo(loop.achievedMultiplier, 2)
  })

  it("calculates price impact from multiplier and liquidity", () => {
    const impact = calculatePriceImpact({
      baseImpact: 0.001,
      multiplier: 3,
      availableLiquidityUsd: 5_000_000,
      collateralValueUsd: 25_000,
    })

    expect(impact).toBeGreaterThan(0.001)
    expect(impact).toBeLessThan(0.02)
  })

  it("calculates max leverage APY from supply, borrow, and multiplier", () => {
    const apy = calculateMaxLeverageApy({
      supplyApy: 0.0514,
      borrowApy: 0.04,
      safeMaxMultiplier: 5,
    })

    expect(apy).toBeCloseTo(0.097, 3)
  })
})
