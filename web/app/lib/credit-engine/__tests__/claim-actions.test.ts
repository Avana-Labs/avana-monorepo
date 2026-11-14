import { describe, expect, it } from "vitest"
import {
  applyBorrowAction,
  assertBorrowSystemInvariants,
  calculateCreditMetrics,
  parseFixed,
} from "@/app/lib/credit-engine"
import { simulateClaim } from "@/app/lib/credit-engine/simulation"
import { EXAMPLE_WALLET_1_REWARD_ID, makeExampleBorrowSystemState } from "@/app/lib/credit-engine/__tests__/fixtures"

describe("claim borrow actions", () => {
  it("claims rewards without changing collateral or debt metrics", () => {
    const state = makeExampleBorrowSystemState()
    const beforeMetrics = calculateCreditMetrics(state, "wallet-1")
    const beforeBalance = state.accounts["wallet-1"]!.walletBalanceUsd6

    const next = applyBorrowAction(state, {
      type: "claim",
      walletId: "wallet-1",
      rewardPositionIds: [EXAMPLE_WALLET_1_REWARD_ID],
      amountUsd6: parseFixed("100", 6),
    })

    const afterMetrics = calculateCreditMetrics(next, "wallet-1")
    const reward = next.accounts["wallet-1"]!.rewardPositions.find(
      (position) => position.id === EXAMPLE_WALLET_1_REWARD_ID,
    )!

    expect(reward.claimableUsd6).toBe(parseFixed("42", 6))
    expect(next.accounts["wallet-1"]!.walletBalanceUsd6).toBe(beforeBalance + parseFixed("100", 6))
    expect(afterMetrics.totalBorrowedUsd6).toBe(beforeMetrics.totalBorrowedUsd6)
    expect(afterMetrics.healthFactorWad).toBe(beforeMetrics.healthFactorWad)
    expect(next.transactions.at(-1)?.kind).toBe("claim")
    assertBorrowSystemInvariants(next)
  })

  it("simulates claim as allowed when reward positions have balances", () => {
    const state = makeExampleBorrowSystemState()
    const simulation = simulateClaim(state, {
      type: "claim",
      walletId: "wallet-1",
      rewardPositionIds: [EXAMPLE_WALLET_1_REWARD_ID],
      amountUsd6: parseFixed("50", 6),
    })

    expect(simulation.allowed).toBe(true)
    expect(simulation.warnings).toEqual([])
    expect(simulation.before.metrics.totalBorrowedUsd6).toBe(simulation.after.metrics.totalBorrowedUsd6)
  })

  it("rejects claims above the selected reward balance", () => {
    const state = makeExampleBorrowSystemState()

    expect(() =>
      applyBorrowAction(state, {
        type: "claim",
        walletId: "wallet-1",
        rewardPositionIds: [EXAMPLE_WALLET_1_REWARD_ID],
        amountUsd6: parseFixed("1000", 6),
      }),
    ).not.toThrow()

    const next = applyBorrowAction(state, {
      type: "claim",
      walletId: "wallet-1",
      rewardPositionIds: [EXAMPLE_WALLET_1_REWARD_ID],
      amountUsd6: parseFixed("1000", 6),
    })

    const reward = next.accounts["wallet-1"]!.rewardPositions.find(
      (position) => position.id === EXAMPLE_WALLET_1_REWARD_ID,
    )!
    expect(reward.claimableUsd6).toBe(0n)
  })
})
