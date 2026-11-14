import { describe, expect, it } from "vitest"
import {
  accrueLiquidityIndex,
  calculateAvailableLiquidity,
  calculateCurrentSuppliedBalance,
  calculateInterestEarned,
  calculateMaxWithdrawable,
  calculateScaledDepositAmount,
  calculateTotalApy,
  calculateUtilization,
  calculateWithdrawSplit,
} from "@/app/lib/lend-engine/formulas"

describe("lend engine formulas", () => {
  it("scaled balance divides by the liquidity index so the current balance round-trips (hydration)", () => {
    // Hydration must store scaledBalance = suppliedAmount / index; the current balance is recovered as
    // scaledBalance × index. Storing the raw supplied amount would re-inflate it by the index (100 →
    // 105 at index 1.05) on the next action.
    const suppliedAmount = 100
    const index = 1.05
    const scaled = calculateScaledDepositAmount(suppliedAmount, index)
    expect(scaled).toBeCloseTo(suppliedAmount / index, 9)
    expect(calculateCurrentSuppliedBalance(scaled, index)).toBeCloseTo(suppliedAmount, 9)
    // The buggy path (scaledBalance = raw amount) would recover an inflated balance.
    expect(calculateCurrentSuppliedBalance(suppliedAmount, index)).toBeCloseTo(suppliedAmount * index, 9)
  })

  it("calculates utilization and available liquidity", () => {
    expect(calculateUtilization(300, 1000)).toBeCloseTo(0.3)
    expect(calculateUtilization(100, 0)).toBe(0)
    expect(calculateAvailableLiquidity(1000, 300)).toBe(700)
  })

  it("calculates total APY", () => {
    expect(calculateTotalApy(0.05, 0.01)).toBeCloseTo(0.06)
  })

  it("accrues liquidity index with simple and compound models", () => {
    expect(accrueLiquidityIndex({ oldLiquidityIndex: 1, supplyApy: 0.1, elapsedYears: 1 })).toBeCloseTo(1.1)
    expect(
      accrueLiquidityIndex({ oldLiquidityIndex: 1, supplyApy: 0.1, elapsedYears: 1, compounding: true }),
    ).toBeCloseTo(Math.exp(0.1))
  })

  it("calculates scaled balances and interest earned", () => {
    expect(calculateScaledDepositAmount(100, 2)).toBe(50)
    expect(calculateCurrentSuppliedBalance(50, 2)).toBe(100)
    expect(calculateInterestEarned(110, 100)).toBe(10)
    expect(calculateMaxWithdrawable(100, 80)).toBe(80)
  })

  it("splits withdraw into principal and interest portions", () => {
    const split = calculateWithdrawSplit({
      withdrawAmount: 50,
      currentBalance: 110,
      principalDeposited: 100,
    })

    expect(split.interestWithdrawn).toBeCloseTo(50 * (10 / 110))
    expect(split.principalWithdrawn).toBeCloseTo(50 - split.interestWithdrawn)
    expect(split.remainingPrincipal).toBeCloseTo(100 - split.principalWithdrawn)
  })
})
