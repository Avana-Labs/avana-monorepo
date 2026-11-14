import { describe, expect, it } from "vitest"
import { principalWeightedBorrowOpenedAt } from "@/app/lib/borrow-system/use-borrow-session"

const DAY = 86_400_000
const YEAR = 365 * DAY
const borrow = (at: number, amountUsd: number, status: "success" | "failed" = "success") => ({
  _id: `tx-${at}`,
  product: "borrow" as const,
  kind: "borrow",
  status,
  marketSlug: "uni-v2-wbtc-weth",
  requestedAmountUsd6: String(amountUsd * 1_000_000),
  executedAmountUsd6: String(amountUsd * 1_000_000),
  syntheticTxHash: `0x${at}`,
  simulated: true,
  at,
})

// The display formula in buildBorrowBalanceMetrics / selectDebtRows.
const interestOwed = (principalUsd: number, rate: number, openedAt: number, now: number) =>
  (principalUsd * rate * (now - openedAt)) / YEAR

describe("borrow Interest Owed open time", () => {
  it("does not jump when a loan is topped up", () => {
    const t0 = Date.parse("2026-08-01T00:00:00Z")
    const topUpAt = t0 + 30 * DAY
    const rate = 0.05

    const beforeTopUp = principalWeightedBorrowOpenedAt([borrow(t0, 1_000)]).get("uni-v2-wbtc-weth")!
    const owedJustBefore = interestOwed(1_000, rate, beforeTopUp, topUpAt)

    const afterTopUp = principalWeightedBorrowOpenedAt([borrow(t0, 1_000), borrow(topUpAt, 9_000)]).get(
      "uni-v2-wbtc-weth",
    )!
    const owedJustAfter = interestOwed(10_000, rate, afterTopUp, topUpAt)

    // Earliest-borrow basis would show 10,000 × 5% × 30d = $41.10 here instead of $4.11.
    expect(owedJustAfter).toBeCloseTo(owedJustBefore, 6)
    expect(owedJustAfter).toBeCloseTo(4.109589, 5)
  })

  it("ignores failed borrows and keeps a single borrow's own time", () => {
    const t0 = Date.parse("2026-09-17T19:18:00Z")
    const openedAt = principalWeightedBorrowOpenedAt([borrow(t0, 2_470.8), borrow(t0 + DAY, 5_000, "failed")])
    expect(openedAt.get("uni-v2-wbtc-weth")).toBe(t0)
  })
})
