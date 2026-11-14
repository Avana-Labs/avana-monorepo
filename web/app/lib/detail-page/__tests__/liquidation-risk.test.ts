import { describe, expect, it } from "vitest"
import { buildMockLiquidationRiskStats, foldLiquidationRiskStats } from "@/app/lib/detail-page/liquidation-risk"

describe("foldLiquidationRiskStats", () => {
  const latest = {
    liquidationsCount: 12,
    collateralSeizedUsd: 1_500_000,
    debtRepaidUsd: 1_400_000,
    liquidationBonusUsd: 75_000,
    collateralAtRiskUsd: 8_000_000,
    walletsAtRisk: 40,
    walletsEligibleForLiquidation: 6,
    badDebtUsd: 1200,
    walletsWithBadDebt: 2,
  }

  const previous = {
    ...latest,
    liquidationsCount: 10,
    collateralAtRiskUsd: 9_000_000,
    walletsAtRisk: 45,
    badDebtUsd: 1500,
  }

  it("builds six KPIs with day-over-day deltas", () => {
    const stats = foldLiquidationRiskStats(latest, previous)
    expect(stats).toHaveLength(6)
    expect(stats.map((s) => s.id)).toEqual([
      "liquidations",
      "collateralSeized",
      "debtRepaid",
      "collateralAtRisk",
      "walletsAtRisk",
      "badDebt",
    ])
    expect(stats.every((s) => s.goodDirection === "down")).toBe(true)

    const liquidations = stats.find((s) => s.id === "liquidations")!
    expect(liquidations.deltaValue).toBe(2)

    const atRisk = stats.find((s) => s.id === "collateralAtRisk")!
    expect(atRisk.deltaValue).toBe(-1_000_000)
  })

  it("treats missing previous day as zero deltas", () => {
    const stats = foldLiquidationRiskStats(latest, null)
    expect(stats.every((s) => s.deltaValue === 0)).toBe(true)
  })
})
