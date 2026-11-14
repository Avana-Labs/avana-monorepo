import { describe, expect, it } from "vitest"
import {
  calculateBorrowPreview,
  calculateRemovePreview,
  calculateRepayPreview,
  HOME_COLLATERAL_POOLS,
  type HomeCollateralPool,
} from "@/app/lib/home-sim"

const pool = HOME_COLLATERAL_POOLS[0] as HomeCollateralPool
// eth-usdc: collateralUsd 4200, maxLtv 70, liquidationUsd 3380
const liquidationThreshold = pool.liquidationUsd / pool.collateralUsd

describe("home-sim health factor uses liquidation threshold, not max-LTV", () => {
  it("borrow HF matches (collateral * liquidationThreshold) / debt", () => {
    const debt = 1_000
    const preview = calculateBorrowPreview(pool, debt, "USDC")

    const expected = (pool.collateralUsd * liquidationThreshold) / debt
    const maxLtvValue = (pool.collateralUsd * (pool.maxLtv / 100)) / debt

    expect(preview.healthFactor).toBeCloseTo(expected, 6)
    // The liquidation-threshold HF is HIGHER than the old max-LTV HF (0.805 vs 0.70).
    expect(preview.healthFactor).not.toBeCloseTo(maxLtvValue, 3)
    expect(preview.healthFactor).toBeGreaterThan(maxLtvValue)
  })

  it("repay HF-after matches liquidation-threshold calc", () => {
    const preview = calculateRepayPreview(pool, 2_000, 500, pool.pairApr)
    const remainingDebt = 1_500

    const expected = (pool.collateralUsd * liquidationThreshold) / remainingDebt
    const maxLtvValue = (pool.collateralUsd * (pool.maxLtv / 100)) / remainingDebt

    expect(preview.healthFactorAfter).toBeCloseTo(expected, 6)
    expect(preview.healthFactorAfter).not.toBeCloseTo(maxLtvValue, 3)
  })

  it("remove HF-after uses remaining collateral * liquidation threshold", () => {
    const preview = calculateRemovePreview(pool, 1_000, 25)
    const afterCollateral = pool.collateralUsd - Math.round((pool.collateralUsd * 25) / 100)

    const expected = (afterCollateral * liquidationThreshold) / 1_000
    const maxLtvValue = (afterCollateral * (pool.maxLtv / 100)) / 1_000

    expect(preview.healthFactorAfter).toBeCloseTo(expected, 6)
    expect(preview.healthFactorAfter).not.toBeCloseTo(maxLtvValue, 3)
  })

  it("debt == 0 keeps HF = Infinity across previews", () => {
    expect(calculateBorrowPreview(pool, 0, "USDC").healthFactor).toBeNull()
    expect(calculateRepayPreview(pool, 0, 0, pool.pairApr).healthFactorAfter).toBe(Number.POSITIVE_INFINITY)
    expect(calculateRemovePreview(pool, 0, 100).healthFactorAfter).toBe(Number.POSITIVE_INFINITY)
  })
})

describe("calculateRemovePreview blocks unsafe removals via isValid", () => {
  it("removing 100% of collateral with open debt is invalid and blocked", () => {
    const preview = calculateRemovePreview(pool, 1_000, 100)

    expect(preview.afterCollateralUsd).toBe(0)
    expect(preview.healthFactorAfter).toBe(0)
    expect(preview.isUnsafe).toBe(true)
    expect(preview.isValid).toBe(false)
    expect(preview.ctaLabel).toBe("Reduce removal amount")
  })

  it("removing beyond the safe floor is invalid even if still solvent", () => {
    const preview = calculateRemovePreview(pool, 1_000, 100)
    // safePercent is well below 100 with open debt
    expect(preview.percent).toBeGreaterThan(preview.safePercent)
    expect(preview.isValid).toBe(false)
  })

  it("a safe removal stays valid with a normal Remove CTA", () => {
    const preview = calculateRemovePreview(pool, 1_000, 10)

    expect(preview.isValid).toBe(true)
    expect(preview.isUnsafe).toBe(false)
    expect(preview.ctaLabel).toMatch(/^Remove 10% ·/)
  })

  it("no-debt removal of 100% is valid", () => {
    const preview = calculateRemovePreview(pool, 0, 100)

    expect(preview.isValid).toBe(true)
    expect(preview.ctaLabel).toMatch(/^Remove 100% ·/)
  })
})
