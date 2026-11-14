import { describe, expect, it } from "vitest"
import { calculateCreditMetrics, formatFixed } from "@/app/lib/credit-engine"
import { accrueBorrowSystemState } from "@/app/lib/credit-engine/accrue"
import { makeExampleBorrowSystemState } from "./fixtures"

describe("borrow state accrual", () => {
  it("accrues market supply indexes and debt indexes forward", () => {
    const start = makeExampleBorrowSystemState()
    const end = accrueBorrowSystemState(start, start.now + 7 * 24 * 60 * 60 * 1000)

    expect(end.markets["uni-v3-bluechip-weth-usdc"]!.snapshot.supplyIndexRay).toBeGreaterThan(
      start.markets["uni-v3-bluechip-weth-usdc"]!.snapshot.supplyIndexRay,
    )
    expect(end.accounts["wallet-1"]!.debtPositions[0]!.debtIndexRay).toBeGreaterThan(
      start.accounts["wallet-1"]!.debtPositions[0]!.debtIndexRay,
    )
  })

  it("increases accrued interest earned and owed over time", () => {
    const start = makeExampleBorrowSystemState()
    const before = calculateCreditMetrics(start, "wallet-1")
    const accrued = accrueBorrowSystemState(start, start.now + 30 * 24 * 60 * 60 * 1000)
    const after = calculateCreditMetrics(accrued, "wallet-1")

    expect(after.interestEarnedUsd6).toBeGreaterThan(before.interestEarnedUsd6)
    expect(after.interestOwedUsd6).toBeGreaterThan(before.interestOwedUsd6)
    expect(formatFixed(after.interestOwedUsd6, 6)).toBe("26.49863")
  })
})
