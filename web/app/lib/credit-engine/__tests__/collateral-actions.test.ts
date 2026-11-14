import { describe, expect, it } from "vitest"
import { calculateCreditMetrics, formatFixed, parseFixed } from "@/app/lib/credit-engine"
import { applyBorrowAction } from "@/app/lib/credit-engine/actions"
import { EXAMPLE_UNI_MARKET_ID, makeExampleBorrowSystemState } from "./fixtures"

describe("borrow collateral actions", () => {
  it("adds collateral and increases credit limit", () => {
    const state = makeExampleBorrowSystemState()
    const beforeWalletLp = state.accounts["wallet-1"]!.walletLpBalancesUsd6[EXAMPLE_UNI_MARKET_ID]
    const next = applyBorrowAction(state, {
      type: "supplyCollateral",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      amountUsd6: parseFixed("1000", 6),
    })

    const metrics = calculateCreditMetrics(next, "wallet-1")
    expect(formatFixed(metrics.poolCollateralValueUsd6, 6)).toBe("21399.224999")
    expect(formatFixed(metrics.creditLimitUsd6, 6)).toBe("15200.395599")
    expect(next.accounts["wallet-1"]!.walletLpBalancesUsd6[EXAMPLE_UNI_MARKET_ID]).toBe(
      beforeWalletLp - parseFixed("1000", 6),
    )
    expect(next.transactions.at(-1)?.kind).toBe("deposit")
  })

  it("removes collateral while keeping the account solvent", () => {
    const state = makeExampleBorrowSystemState()
    const beforeWalletLp = state.accounts["wallet-1"]!.walletLpBalancesUsd6[EXAMPLE_UNI_MARKET_ID]
    const next = applyBorrowAction(state, {
      type: "removeCollateral",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      amountUsd6: parseFixed("1000", 6),
    })

    const metrics = calculateCreditMetrics(next, "wallet-1")
    expect(formatFixed(metrics.poolCollateralValueUsd6, 6)).toBe("19399.225")
    expect(formatFixed(metrics.healthFactorWad, 18)).toBe("2.532309370967741935")
    expect(next.accounts["wallet-1"]!.walletLpBalancesUsd6[EXAMPLE_UNI_MARKET_ID]).toBe(
      beforeWalletLp + parseFixed("1000", 6),
    )
    expect(next.transactions.at(-1)?.kind).toBe("withdraw")
  })

  it("rejects collateral supplies that exceed the wallet LP balance", () => {
    const state = makeExampleBorrowSystemState()

    expect(() =>
      applyBorrowAction(state, {
        type: "supplyCollateral",
        walletId: "wallet-1",
        marketId: EXAMPLE_UNI_MARKET_ID,
        amountUsd6: parseFixed("9000", 6),
      }),
    ).toThrow("Wallet has insufficient LP balance for this collateral deposit")
  })

  it("rejects collateral removals that would make the account insolvent", () => {
    const state = makeExampleBorrowSystemState()

    expect(() =>
      applyBorrowAction(state, {
        type: "removeCollateral",
        walletId: "wallet-1",
        positionId: "wallet-1:weth-usdc",
        percentBps: 10_000,
      }),
    ).toThrow("Removing collateral would make wallet wallet-1 insolvent")
  })

  it("rejects collateral removals that only break spoke health while wallet totals still look solvent", () => {
    const state = makeExampleBorrowSystemState()

    expect(() =>
      applyBorrowAction(state, {
        type: "removeCollateral",
        walletId: "wallet-1",
        positionId: "wallet-1:weth-usdc",
        amountUsd6: parseFixed("8000", 6),
      }),
    ).toThrow("Removing collateral would make spoke uni-v3-bluechip insolvent")
  })
})
