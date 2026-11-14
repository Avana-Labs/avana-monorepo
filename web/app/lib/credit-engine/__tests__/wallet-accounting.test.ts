import { describe, expect, it } from "vitest"
import { calculateCreditMetrics, parseFixed } from "@/app/lib/credit-engine"
import { applyBorrowAction } from "@/app/lib/credit-engine/actions"
import {
  EXAMPLE_UNI_MARKET_ID,
  EXAMPLE_UNI_USDC_ASSET_ID,
  EXAMPLE_WALLET_1_DEBT_ID,
  makeExampleBorrowSystemState,
} from "./fixtures"

const ONE_USD = parseFixed("1", 6)

function abs(value: bigint) {
  return value < 0n ? -value : value
}

describe("borrow/repay wallet accounting", () => {
  it("credits the wallet balance with borrowed funds", () => {
    const state = makeExampleBorrowSystemState()
    const before = state.accounts["wallet-1"]!.walletBalanceUsd6
    const beforeNet = calculateCreditMetrics(state, "wallet-1").netAccountValueUsd6

    const next = applyBorrowAction(state, {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: parseFixed("1000", 6),
    })

    expect(next.accounts["wallet-1"]!.walletBalanceUsd6).toBe(before + parseFixed("1000", 6))
    // Borrowing must not change net worth: you receive cash AND owe it.
    const afterNet = calculateCreditMetrics(next, "wallet-1").netAccountValueUsd6
    expect(abs(afterNet - beforeNet)).toBeLessThanOrEqual(ONE_USD)
  })

  it("debits the wallet balance when repaying debt", () => {
    const state = makeExampleBorrowSystemState()
    const before = state.accounts["wallet-1"]!.walletBalanceUsd6

    const next = applyBorrowAction(state, {
      type: "repay",
      walletId: "wallet-1",
      debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
      amountUsd6: parseFixed("1000", 6),
    })

    expect(before - next.accounts["wallet-1"]!.walletBalanceUsd6).toBe(parseFixed("1000", 6))
  })

  it("caps repayment at the available wallet balance", () => {
    const state = makeExampleBorrowSystemState()
    state.accounts["wallet-1"]!.walletBalanceUsd6 = parseFixed("300", 6)
    const debtBefore = calculateCreditMetrics(state, "wallet-1").totalBorrowedUsd6

    const next = applyBorrowAction(state, {
      type: "repay",
      walletId: "wallet-1",
      debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
      amountUsd6: parseFixed("1000", 6),
    })

    expect(next.accounts["wallet-1"]!.walletBalanceUsd6).toBe(0n)
    const debtAfter = calculateCreditMetrics(next, "wallet-1").totalBorrowedUsd6
    expect(abs(debtBefore - debtAfter - parseFixed("300", 6))).toBeLessThanOrEqual(ONE_USD)
  })

  it("rejects a repay when the wallet has no balance", () => {
    const state = makeExampleBorrowSystemState()
    state.accounts["wallet-1"]!.walletBalanceUsd6 = 0n

    expect(() =>
      applyBorrowAction(state, {
        type: "repay",
        walletId: "wallet-1",
        debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
        amountUsd6: parseFixed("1000", 6),
      }),
    ).toThrow(/insufficient balance/i)
  })
})
