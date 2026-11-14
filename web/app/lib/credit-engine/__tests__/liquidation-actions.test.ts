import { describe, expect, it } from "vitest"
import {
  assertBorrowSystemInvariants,
  calculateCreditMetrics,
  currentDebtValueUsd6,
  parseFixed,
} from "@/app/lib/credit-engine"
import { applyBorrowAction } from "@/app/lib/credit-engine/actions"
import { EXAMPLE_WALLET_1_DEBT_ID, makeExampleBorrowSystemState } from "./fixtures"

describe("borrow liquidation actions", () => {
  it("rejects liquidation while the account is still solvent", () => {
    const state = makeExampleBorrowSystemState()

    expect(() =>
      applyBorrowAction(state, {
        type: "liquidate",
        walletId: "wallet-1",
        positionId: "wallet-1:weth-usdc",
        debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
        repayAmountUsd6: parseFixed("1000", 6),
      }),
    ).toThrow("Wallet wallet-1 is not eligible for liquidation")
  })

  it("partially liquidates an underwater account without over-seizing collateral", () => {
    const state = makeExampleBorrowSystemState()
    const debt = state.accounts["wallet-1"]!.debtPositions[0]!
    debt.principalBorrowedUsd6 = parseFixed("18000", 6)
    debt.debtSharesUsd6 = parseFixed("18000", 6)

    const beforeMetrics = calculateCreditMetrics(state, "wallet-1")
    const beforeCollateralShares = state.accounts["wallet-1"]!.collateralPositions[0]!.collateralShares
    const beforeDebtUsd6 = currentDebtValueUsd6(debt)
    expect(beforeMetrics.healthFactorWad).toBeLessThan(parseFixed("1", 18))

    const next = applyBorrowAction(state, {
      type: "liquidate",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
      repayAmountUsd6: parseFixed("2000", 6),
    })

    const afterDebt = next.accounts["wallet-1"]!.debtPositions[0]!
    const afterCollateral = next.accounts["wallet-1"]!.collateralPositions[0]!
    const afterMetrics = calculateCreditMetrics(next, "wallet-1")

    expect(currentDebtValueUsd6(afterDebt)).toBeLessThan(beforeDebtUsd6)
    expect(afterCollateral.collateralShares).toBeLessThan(beforeCollateralShares)
    expect(afterCollateral.collateralShares).toBeGreaterThanOrEqual(0n)
    expect(next.transactions.at(-1)?.kind).toBe("liquidate")
    expect(next.transactions.at(-1)?.amountUsd6).toBe(parseFixed("2000", 6))
    expect(afterMetrics.totalBorrowedUsd6).toBe(parseFixed("16000", 6))
    assertBorrowSystemInvariants(next)
  })

  it("preserves residual debt shares when principal is already zero during liquidation", () => {
    const state = makeExampleBorrowSystemState()
    const debt = state.accounts["wallet-1"]!.debtPositions[0]!
    debt.principalBorrowedUsd6 = 0n
    debt.debtSharesUsd6 = parseFixed("20000", 6)

    const next = applyBorrowAction(state, {
      type: "liquidate",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
      repayAmountUsd6: parseFixed("1000", 6),
    })

    const remaining = next.accounts["wallet-1"]!.debtPositions.find(
      (position) => position.id === EXAMPLE_WALLET_1_DEBT_ID,
    )
    expect(remaining).toBeDefined()
    expect(remaining?.principalBorrowedUsd6).toBe(0n)
    expect(remaining?.debtSharesUsd6).toBe(parseFixed("19000", 6))
  })
})
