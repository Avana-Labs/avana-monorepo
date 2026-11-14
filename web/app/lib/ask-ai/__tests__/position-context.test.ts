import { describe, expect, it } from "vitest"
import {
  buildPositionContext,
  computeBorrowCapacity,
  computeFeePerDay,
  computeInterestPerDay,
  computeLiquidationBoundaryCurve,
  computeLiquidationBuffer,
  computeNetCarry,
  rankComparableLPs,
  riskLevelFromHealthFactor,
  simulateStress,
  snapshotIdFor,
  type PositionSnapshotInput,
} from "../position-context"

const baseInput: PositionSnapshotInput = {
  positionId: "pos_1",
  product: "borrow",
  collateralValueUsd: 10_000,
  debtValueUsd: 4_000,
  maxLtvPct: 55,
  liquidationThresholdPct: 65,
  borrowApyPct: 5,
  lpFeeApr7dPct: 18.25,
  constituents: [
    { symbol: "ETH", weight: 0.5, feeApr7dPct: 20 },
    { symbol: "USDC", weight: 0.5, feeApr7dPct: 4 },
  ],
  lastUpdatedAt: 1_700_000_000_000,
}

const ctx = buildPositionContext(baseInput, 1_700_000_100_000)

describe("buildPositionContext", () => {
  it("derives current LTV and health factor from a single snapshot", () => {
    expect(ctx.currentLtv).toBeCloseTo(0.4, 10)
    // 10000 * 0.65 / 4000
    expect(ctx.healthFactor).toBeCloseTo(1.625, 10)
    expect(ctx.liquidationThresholdPct).toBe(65)
  })

  it("reports no debt as an infinite (null) health factor", () => {
    const noDebt = buildPositionContext({ ...baseInput, debtValueUsd: 0 }, 1)
    expect(noDebt.healthFactor).toBeNull()
    expect(noDebt.currentLtv).toBe(0)
  })

  it("falls back to a maxLtv-derived liquidation threshold when none is given", () => {
    const derived = buildPositionContext({ ...baseInput, liquidationThresholdPct: undefined }, 1)
    expect(derived.liquidationThresholdPct).toBeGreaterThan(derived.maxLtvPct)
  })

  it("returns a frozen, immutable snapshot", () => {
    expect(Object.isFrozen(ctx)).toBe(true)
    expect(Object.isFrozen(ctx.constituents)).toBe(true)
    expect(Object.isFrozen(ctx.constituents[0])).toBe(true)
  })
})

describe("snapshotIdFor", () => {
  it("is deterministic for identical inputs and timestamp", () => {
    expect(snapshotIdFor(baseInput, 42)).toBe(snapshotIdFor({ ...baseInput }, 42))
  })

  it("changes when the timestamp or a value changes", () => {
    expect(snapshotIdFor(baseInput, 42)).not.toBe(snapshotIdFor(baseInput, 43))
    expect(snapshotIdFor(baseInput, 42)).not.toBe(snapshotIdFor({ ...baseInput, debtValueUsd: 4_001 }, 42))
  })
})

describe("computeBorrowCapacity", () => {
  it("computes max-LTV room and borrowable amounts at health-factor targets", () => {
    const capacity = computeBorrowCapacity(ctx)
    expect(capacity.maxDebtUsd).toBeCloseTo(5_500, 6) // 10000 * 0.55
    expect(capacity.availableUsd).toBeCloseTo(1_500, 6)
    // liquidation value 6500; at HF 1.5 -> 6500/1.5 - 4000; at HF 2 -> clamps to 0
    expect(capacity.atHfTargets[0]).toMatchObject({ healthFactor: 1.5 })
    expect(capacity.atHfTargets[0].borrowableUsd).toBeCloseTo(333.333, 2)
    expect(capacity.atHfTargets[1].borrowableUsd).toBe(0)
  })
})

describe("computeLiquidationBuffer", () => {
  it("reports how far collateral can fall before liquidation", () => {
    // (1 - 1/1.625) * 100
    expect(computeLiquidationBuffer(ctx).bufferPct).toBeCloseTo(38.4615, 3)
    expect(computeLiquidationBuffer(ctx).riskLevel).toBe("low")
  })

  it("treats a debt-free position as a full 100% buffer", () => {
    const noDebt = buildPositionContext({ ...baseInput, debtValueUsd: 0 }, 1)
    expect(computeLiquidationBuffer(noDebt).bufferPct).toBe(100)
  })

  it("clamps an already-underwater position to a 0% buffer", () => {
    const underwater = buildPositionContext({ ...baseInput, debtValueUsd: 8_000 }, 1)
    expect(computeLiquidationBuffer(underwater).bufferPct).toBe(0)
    expect(computeLiquidationBuffer(underwater).riskLevel).toBe("critical")
  })
})

describe("computeInterestPerDay", () => {
  it("computes daily interest from the borrow rate", () => {
    expect(computeInterestPerDay(ctx).interestPerDayUsd).toBeCloseTo((4_000 * 0.05) / 365, 8)
  })

  it("returns null when there is debt but the rate is unknown", () => {
    const noRate = buildPositionContext({ ...baseInput, borrowApyPct: undefined }, 1)
    expect(computeInterestPerDay(noRate).interestPerDayUsd).toBeNull()
  })

  it("returns 0 when there is no debt", () => {
    const noDebt = buildPositionContext({ ...baseInput, debtValueUsd: 0, borrowApyPct: undefined }, 1)
    expect(computeInterestPerDay(noDebt).interestPerDayUsd).toBe(0)
  })
})

describe("computeFeePerDay", () => {
  it("uses the whole-position fee APR when present", () => {
    expect(computeFeePerDay(ctx).feePerDayUsd).toBeCloseTo(5, 8) // 10000 * 0.1825 / 365
  })

  it("falls back to a weight-blended fee APR across priced legs", () => {
    const blended = buildPositionContext({ ...baseInput, lpFeeApr7dPct: undefined }, 1)
    expect(computeFeePerDay(blended).feeApr7dPct).toBeCloseTo(12, 6) // (0.5*20 + 0.5*4)
  })

  it("returns null when no fee data is available", () => {
    const noFee = buildPositionContext(
      { ...baseInput, lpFeeApr7dPct: undefined, constituents: [{ symbol: "ETH", weight: 1 }] },
      1,
    )
    expect(computeFeePerDay(noFee).feePerDayUsd).toBeNull()
  })
})

describe("computeNetCarry", () => {
  it("nets fee income against borrow interest and projects it out", () => {
    const carry = computeNetCarry(ctx)
    const expectedPerDay = 5 - (4_000 * 0.05) / 365
    expect(carry.netCarryPerDayUsd).toBeCloseTo(expectedPerDay, 8)
    expect(carry.projected7dUsd).toBeCloseTo(expectedPerDay * 7, 6)
    expect(carry.projected30dUsd).toBeCloseTo(expectedPerDay * 30, 6)
  })

  it("is null when a required input is unavailable", () => {
    const noFee = buildPositionContext(
      { ...baseInput, lpFeeApr7dPct: undefined, constituents: [{ symbol: "ETH", weight: 1 }] },
      1,
    )
    expect(computeNetCarry(noFee).netCarryPerDayUsd).toBeNull()
  })
})

describe("simulateStress", () => {
  it("applies a uniform collateral shock", () => {
    const stressed = simulateStress(ctx, -20)
    expect(stressed.shockedCollateralValueUsd).toBe(8_000)
    expect(stressed.healthFactor).toBeCloseTo(1.3, 10)
    expect(stressed.liquidated).toBe(false)
  })

  it("flags liquidation once the shock pushes HF to 1 or below", () => {
    expect(simulateStress(ctx, -50).liquidated).toBe(true)
  })
})

describe("computeLiquidationBoundaryCurve", () => {
  it("locates the exact liquidation shock and matches the buffer", () => {
    const curve = computeLiquidationBoundaryCurve(ctx)
    expect(curve.liquidationPriceShockPct).toBeCloseTo(-38.4615, 3)
    expect(curve.points[0]).toMatchObject({ priceShockPct: 0 })
    expect(curve.points[0].healthFactor).toBeCloseTo(1.625, 10)
  })

  it("has no liquidation shock for a debt-free position", () => {
    const noDebt = buildPositionContext({ ...baseInput, debtValueUsd: 0 }, 1)
    expect(computeLiquidationBoundaryCurve(noDebt).liquidationPriceShockPct).toBeNull()
  })
})

describe("rankComparableLPs", () => {
  it("ranks candidates by net APY, best first", () => {
    const ranked = rankComparableLPs(ctx, [
      { id: "a", label: "A", feeApr7dPct: 12, borrowApyPct: 0 },
      { id: "b", label: "B", feeApr7dPct: 20, borrowApyPct: 5 }, // net 15
      { id: "c", label: "C", feeApr7dPct: 10, borrowApyPct: 2 }, // net 8
    ])
    expect(ranked.map((r) => r.id)).toEqual(["b", "a", "c"])
    expect(ranked[0].netApyPct).toBe(15)
  })
})

describe("riskLevelFromHealthFactor", () => {
  it("maps health factors to the shared risk bands", () => {
    expect(riskLevelFromHealthFactor(null)).toBe("low")
    expect(riskLevelFromHealthFactor(2)).toBe("low")
    expect(riskLevelFromHealthFactor(1.3)).toBe("elevated")
    expect(riskLevelFromHealthFactor(0.9)).toBe("critical")
  })
})
